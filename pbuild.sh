#!/usr/bin/env sh
# pbuild — gerenciador de programas POSIX para Linux From Scratch
# Autor: você + ChatGPT
# Licença: MIT
#
# Objetivo:
#  - Construir pacotes em /tmp/pbuild/<nome>
#  - Baixar fontes automaticamente (curl/git)
#  - Descompactar formatos comuns (tar.*, zip, gz/xz/bz2 simples)
#  - Aplicar patches
#  - Compilar, testar, instalar com DESTDIR usando fakeroot
#  - Empacotar (tar.xz por padrão) e instalar binário a partir do pacote
#  - Log por pacote em /tmp/pbuild/<nome>/pbuild.log
#  - Saída colorida + spinner
#  - "info", "search" por receitas no $REPO/{base,x11,extras,desktop}
#  - Registros em $REGISTRO (arquivos instalados por pacote, metadados)
#  - Rebuild, strip opcional, revdep simples com correção (tentativa de rebuild)
#  - Hook de pós-remove ($HOOKS/post_remove.d)
#  - Variáveis configuráveis (veja seção CONFIG)
#  - Toolchain: permite subárvore do próprio pacote (ex: $REPO/base/gcc-12.0/{gcc-pass1.pbuild,gcc-12.0})
#
# Requisitos de runtime:
#   POSIX sh, coreutils, curl, git (opcional), fakeroot, tar, xz, gzip, bzip2, unzip (se usar zip), patch, file, ldd (glibc), find, xargs

set -eu

###############################################################################
# CONFIG – Ajuste por ambiente
###############################################################################
: "${TMPROOT:=/tmp/pbuild}"           # Raiz de build
: "${REPO:=/opt/pbuild-repo}"         # Onde ficam as receitas: $REPO/{base,x11,extras,desktop}
: "${SOURCES:=/var/cache/pbuild/src}"  # Onde salvar fontes
: "${REGISTRO:=/var/lib/pbuild}"       # DB simples de pacotes (arquivos, metas)
: "${PKGOUT:=/var/cache/pbuild/pkg}"    # Onde salvar pacotes binários gerados
: "${HOOKS:=/etc/pbuild/hooks}"        # Hooks (pós-remove etc.)
: "${MAKEFLAGS:=${MAKEFLAGS:-}}"        # Respeita MAKEFLAGS existente
: "${JOBS:=auto}"                      # auto => núcleos
: "${STRIP:=yes}"                      # yes/no
: "${PKGCOMP:=xz}"                     # xz|gz|bz2
: "${COLOR:=auto}"                     # auto|always|never

umask 022

mkdir -p "$SOURCES" "$REGISTRO" "$PKGOUT" "$HOOKS" "$TMPROOT"

###############################################################################
# CORES & UI
###############################################################################
_is_tty() { [ -t 1 ] && [ "${COLOR}" != "never" ]; }
if _is_tty; then
  [ "${COLOR}" = "always" ] && :
  ESC="\033"; BOLD="${ESC}[1m"; DIM="${ESC}[2m"; RESET="${ESC}[0m"
  RED="${ESC}[31m"; GREEN="${ESC}[32m"; YELLOW="${ESC}[33m"; BLUE="${ESC}[34m"
else
  BOLD=""; DIM=""; RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""
fi

log()  { printf "%s\n" "$*"; }
info() { printf "%s::%s %s%s\n" "$BLUE" "$RESET" "$*" "$RESET"; }
ok()   { printf "%s==>%s %s%s\n" "$GREEN" "$RESET" "$*" "$RESET"; }
warn() { printf "%s!! %s %s%s\n" "$YELLOW" "$RESET" "$*" "$RESET"; }
err()  { printf "%s** %s %s%s\n" "$RED" "$RESET" "$*" "$RESET" 1>&2; }

spinner_start() {
  _sp_pid=
  if _is_tty; then
    (
      while :; do for c in / - \\ |; do printf "\r%s" "$c"; sleep 0.1; done; done
    ) & _sp_pid=$!
    printf "\r"
  fi
}
spinner_stop() {
  [ -n "${_sp_pid:-}" ] && kill "$_sp_pid" >/dev/null 2>&1 || true
  [ -n "${_sp_pid:-}" ] && wait "$_sp_pid" 2>/dev/null || true
  _sp_pid=""
  _is_tty && printf "\r "
}

run() {
  # run "descrição" comando...
  desc=$1; shift
  info "$desc"
  : >"$LOG"
  spinner_start
  # redireciona stdout+stderr para tee no LOG
  ( set +e; "$@" 2>&1 | tee -a "$LOG"; printf "\n"; exit ${PIPESTATUS-0} )
  rc=$?
  spinner_stop
  [ $rc -eq 0 ] && ok "$desc concluído" || { err "$desc falhou (rc=$rc). Veja: $LOG"; exit $rc; }
}

###############################################################################
# UTILIDADES
###############################################################################
cores() { printf "%sBOLD%s %sRED%s %sGREEN%s %sYELLOW%s %sBLUE%s\n" "$BOLD" "$RESET" "$RED" "$RESET" "$GREEN" "$RESET" "$YELLOW" "$RESET" "$BLUE"; }
_cpun() { n=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1); [ "$n" -gt 0 ] || n=1; printf "%s" "$n"; }
_jobs() { [ "$JOBS" = auto ] && printf "%s" "$(_cpun)" || printf "%s" "$JOBS"; }

mkbuilddir() {
  PKG_NAME=$1
  BUILD_DIR="$TMPROOT/$PKG_NAME"
  SRC_DIR="$BUILD_DIR/src"
  STAGE_DIR="$BUILD_DIR/pkgroot"   # DESTDIR
  LOG="$BUILD_DIR/pbuild.log"
  mkdir -p "$BUILD_DIR" "$SRC_DIR" "$STAGE_DIR"
}

save_meta() {
  # Salva metadados essenciais
  pkg=$1; shift
  meta="$REGISTRO/$pkg.META"
  {
    printf "name=%s\n" "$pkg"
    printf "version=%s\n" "${PKGVER:-}"
    printf "recipe=%s\n" "$RECIPE"
    printf "built_at=%s\n" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf "strip=%s\n" "$STRIP"
    printf "jobs=%s\n" "$(_jobs)"
  } > "$meta"
}

record_filelist() {
  pkg=$1
  find / -xdev -type f -newer "$_install_stamp" 2>/dev/null | sort >"$REGISTRO/$pkg.files" || true
}

list_files_from_destdir() {
  # Lista arquivos instalados pelo pacote a partir do DESTDIR
  find "$STAGE_DIR" -type f | sed "s#^$STAGE_DIR##" | sort
}

###############################################################################
# RECEITAS – formato simples estilo que você propôs
###############################################################################
# Exemplo de receita (.pbuild):
#   pkgname=[man-db]
#   pkgver=[2.0]
#   pkgurl=[https://example.org/man-db-2.0.tar.xz]
#   md5sum=[deadbeef...]
#   build=[./configure --prefix=/usr]
#   check=[make check]
#   install=[make install]
# Campos adicionais opcionais:
#   pkgdir=[man-db-2.0]               # nome do dir após extração (se não der para deduzir)
#   patches=[file1.patch file2.patch] # nomes relativos ao $SOURCES
#   vcs=[git]                         # usa git clone em vez de curl
#   vcs_branch=[main]
#   makeflags=[-j8]
#   destsubdir=[. or build]           # subdir de build (útil p/ cmake/meson)
#   toolchain=[yes|no]                # só para organização

parse_recipe() {
  RECIPE=$1
  [ -f "$RECIPE" ] || { err "Receita não encontrada: $RECIPE"; exit 2; }
  # limpa variáveis anteriores
  unset PKGNAME PKGVER PKGURL MD5SUM BUILD CHECK INSTALL PKGDIR PATCHES VCS VCS_BRANCH MAKEFLAGS_R DESTSUBDIR TOOLCHAIN
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      \#*|'' ) continue ;;
      *"=["*"]"* )
        key=$(printf "%s" "$line" | sed -n 's/^\([^=][^=]*\)=\[.*\].*$/\1/p' | tr -d ' ')
        val=$(printf "%s" "$line" | sed -n 's/^[^=][^=]*=\[\(.*\)\].*$/\1/p')
        case "$key" in
          pkgname)   PKGNAME=$val ;;
          pkgver)    PKGVER=$val ;;
          pkgurl)    PKGURL=$val ;;
          md5sum)    MD5SUM=$val ;;
          build)     BUILD=$val ;;
          check)     CHECK=$val ;;
          install)   INSTALL=$val ;;
          pkgdir)    PKGDIR=$val ;;
          patches)   PATCHES=$val ;;
          vcs)       VCS=$val ;;
          vcs_branch) VCS_BRANCH=$val ;;
          makeflags) MAKEFLAGS_R=$val ;;
          destsubdir) DESTSUBDIR=$val ;;
          toolchain) TOOLCHAIN=$val ;;
        esac
      ;;
    esac
  done < "$RECIPE"

  [ -n "${PKGNAME:-}" ] || { err "pkgname ausente"; exit 2; }
  [ -n "${PKGVER:-}" ] || { err "pkgver ausente"; exit 2; }
  [ -n "${PKGURL:-}" ] || { err "pkgurl ausente"; exit 2; }

  # Deduções
  : "${PKGDIR:=$(basename "$PKGURL" | sed 's/\.[^.]*$//' | sed 's/\.[^.]*$//') }" # remove .tar.xz/.tar.gz etc
}

###############################################################################
# DOWNLOAD & EXTRAÇÃO
###############################################################################
fetch() {
  url=$1; out=$2
  case "${VCS:-}" in
    git)
      branch_opt=""; [ -n "${VCS_BRANCH:-}" ] && branch_opt="-b $VCS_BRANCH"
      run "Clonando git $url" git clone --depth 1 $branch_opt "$url" "$out.git"
      # cria tar a partir do git para padronizar fluxo
      (cd "$out.git" && git archive --format=tar --output="$out.tar" HEAD)
      rm -rf "$out.git"
      mv "$out.tar" "$out"
      ;;
    *)
      run "Baixando $url" curl -L --fail -o "$out" "$url"
      ;;
  esac
}

verify_md5() {
  [ -n "${MD5SUM:-}" ] || return 0
  printf "%s  %s\n" "$MD5SUM" "$1" | md5sum -c - >/dev/null 2>&1 || { err "MD5 não confere"; exit 3; }
}

extract_any() {
  # Suporta: .tar.xz .tar.gz .tar.bz2 .txz .tgz .tbz2 .zip .xz .gz .bz2 .tar
  archive=$1; dest=$2
  mkdir -p "$dest"
  case "$archive" in
    *.tar.xz|*.txz)   tar -xJf "$archive" -C "$dest" ;;
    *.tar.gz|*.tgz)   tar -xzf "$archive" -C "$dest" ;;
    *.tar.bz2|*.tbz2) tar -xjf "$archive" -C "$dest" ;;
    *.tar)            tar -xf "$archive" -C "$dest" ;;
    *.zip)            unzip -q "$archive" -d "$dest" ;;
    *.xz)             xz -dc "$archive" | tar -x -C "$dest" 2>/dev/null || mkdir -p "$dest" && xz -dk "$archive" && mv "${archive%.xz}" "$dest" ;;
    *.gz)             gzip -dc "$archive" | tar -x -C "$dest" 2>/dev/null || mkdir -p "$dest" && gzip -dk "$archive" && mv "${archive%.gz}" "$dest" ;;
    *.bz2)            bzip2 -dc "$archive" | tar -x -C "$dest" 2>/dev/null || mkdir -p "$dest" && bzip2 -dk "$archive" && mv "${archive%.bz2}" "$dest" ;;
    *) err "Formato não suportado: $archive"; exit 4 ;;
  esac
}

apply_patches() {
  [ -n "${PATCHES:-}" ] || return 0
  for p in $PATCHES; do
    patch_file="$SOURCES/$p"
    [ -f "$patch_file" ] || { err "Patch não encontrado: $patch_file"; exit 5; }
    info "Aplicando patch $p"
    patch -Np1 -i "$patch_file"
  done
}

###############################################################################
# BUILD FLOW
###############################################################################
_do_build() {
  RECIPE=$1
  parse_recipe "$RECIPE"
  mkbuilddir "$PKGNAME"
  save_meta "$PKGNAME"

  ARCHIVE_NAME=$(basename "$PKGURL")
  ARCHIVE_PATH="$SOURCES/$ARCHIVE_NAME"

  [ -f "$ARCHIVE_PATH" ] || fetch "$PKGURL" "$ARCHIVE_PATH"
  verify_md5 "$ARCHIVE_PATH"

  run "Extraindo $ARCHIVE_NAME" extract_any "$ARCHIVE_PATH" "$SRC_DIR"
  # tenta localizar diretório principal
  SRC_TOP=${PKGDIR:-$(ls -1 "$SRC_DIR" | head -n1)}
  cd "$SRC_DIR/$SRC_TOP"

  apply_patches

  # Subdiretório de build
  if [ -n "${DESTSUBDIR:-}" ] && [ "$DESTSUBDIR" != "." ]; then
    mkdir -p "$DESTSUBDIR"
    cd "$DESTSUBDIR"
  fi

  # MAKEFLAGS
  if [ -n "${MAKEFLAGS_R:-}" ]; then
    export MAKEFLAGS="$MAKEFLAGS $MAKEFLAGS_R"
  elif [ -z "${MAKEFLAGS:-}" ]; then
    export MAKEFLAGS="-j$(_jobs)"
  fi

  # BUILD / CHECK / INSTALL
  [ -n "${BUILD:-}" ]   && run "Config/Build" sh -c "$BUILD"
  [ -n "${CHECK:-}" ]   && run "Testes" sh -c "$CHECK"

  # Instalação com DESTDIR
  _install_stamp="$BUILD_DIR/.install.start"
  : >"$_install_stamp"
  if [ -n "${INSTALL:-}" ]; then
    run "Instalação (DESTDIR)" fakeroot sh -c "DESTDIR='$STAGE_DIR' $INSTALL"
  else
    warn "Campo install=[] ausente; nada instalado em DESTDIR"
  fi

  # Strip opcional
  if [ "${STRIP}" = "yes" ]; then
    find "$STAGE_DIR" -type f \( -name "*.so*" -o -perm -111 \) 2>/dev/null | while IFS= read -r f; do
      file "$f" | grep -q "ELF" && strip --strip-unneeded "$f" 2>/dev/null || true
    done
  fi

  # Empacotamento
  PKGFILE="$PKGOUT/${PKGNAME}-${PKGVER}.tar.$PKGCOMP"
  ( cd "$STAGE_DIR" && case "$PKGCOMP" in
      xz) tar -cJf "$PKGFILE" . ;;
      gz) tar -czf "$PKGFILE" . ;;
      bz2) tar -cjf "$PKGFILE" . ;;
    esac )
  ok "Pacote gerado: $PKGFILE"

  # Instalação real no sistema a partir do pacote
  _install_pkg "$PKGFILE" "$PKGNAME"
}

_install_pkg() {
  PKGFILE=$1; PKGNAME=${2:-}
  [ -f "$PKGFILE" ] || { err "Pacote não encontrado: $PKGFILE"; exit 6; }
  info "Instalando binário: $PKGFILE"
  case "$PKGFILE" in
    *.tar.xz)  tar -xJf "$PKGFILE" -C / ;;
    *.tar.gz)  tar -xzf "$PKGFILE" -C / ;;
    *.tar.bz2) tar -xjf "$PKGFILE" -C / ;;
    *) err "Formato de pacote desconhecido"; exit 6 ;;
  esac
  # Registro de arquivos instalados a partir do pacote
  if [ -n "$PKGNAME" ]; then
    # Recria lista a partir do tar
    tar -tf "$PKGFILE" | sed 's#^/#/#' >"$REGISTRO/$PKGNAME.files" || true
  fi
}

remove_pkg() {
  pkg=$1
  flist="$REGISTRO/$pkg.files"
  [ -f "$flist" ] || { err "Sem registro de arquivos: $pkg"; exit 7; }
  warn "Removendo arquivos do pacote $pkg"
  # Remove somente arquivos; ignora diretórios vazios
  sed 's#^/#/#' "$flist" | while IFS= read -r f; do [ -f "$f" ] && rm -f "$f" || true; done
  # Limpa diretórios vazios que restaram
  tac "$flist" | sed 's#/[^/]*$##' | uniq | while IFS= read -r d; do [ -d "$d" ] && rmdir "$d" 2>/dev/null || true; done
  rm -f "$REGISTRO/$pkg.files" "$REGISTRO/$pkg.META" 2>/dev/null || true
  # Hooks pós-remove
  if [ -d "$HOOKS/post_remove.d" ]; then
    for h in "$HOOKS"/post_remove.d/*; do [ -x "$h" ] && "$h" "$pkg" || true; done
  fi
  ok "Pacote $pkg removido"
}

info_pkg() {
  pkg=$1
  meta="$REGISTRO/$pkg.META"
  [ -f "$meta" ] || { err "Sem META para $pkg"; exit 8; }
  ok "Info de $pkg"; cat "$meta"
}

search_recipes() {
  term=$1
  find "$REPO" -type f -name '*.pbuild' -print | while IFS= read -r f; do
    base=$(basename "$f")
    case "$base" in
      *"$term"* ) printf "%s\n" "$f" ;;
    esac
  done
}

revdep_check() {
  # Varre binários e libs e checa libs ausentes
  missing=""
  info "Checando dependências compartilhadas ausentes (revdep)"
  find / -xdev \( -type f -perm -111 -o -name "*.so*" \) 2>/dev/null |
    xargs file 2>/dev/null | grep ELF | cut -d: -f1 | while IFS= read -r f; do
      ldd "$f" 2>/dev/null | grep "not found" || true
    done | awk '{print $1}' | sort -u >"$TMPROOT/.missing.libs" || true
  if [ -s "$TMPROOT/.missing.libs" ]; then
    warn "Bibliotecas ausentes:"; cat "$TMPROOT/.missing.libs"
    missing=1
  fi
  [ -n "$missing" ] || ok "Sem libs ausentes detectadas"
}

revdep_fix() {
  # tentativa simples: encontra pacotes que fornecem libs ausentes pelo registro e recompila
  [ -s "$TMPROOT/.missing.libs" ] || { ok "Nada para corrigir"; return 0; }
  while IFS= read -r lib; do
    # Quem deveria fornecer? busca no histórico simples (.files)
    for f in "$REGISTRO"/*.files; do
      grep -q "/$(basename "$lib")$" "$f" && pkg=$(basename "$f" .files) || true
      [ -n "${pkg:-}" ] && break || true
    done
    if [ -n "${pkg:-}" ]; then
      warn "Tentando recompilar $pkg para restaurar $lib"
      # procura receita do pkg
      rfile=$(find "$REPO" -type f -name "${pkg}*.pbuild" | head -n1 || true)
      if [ -n "$rfile" ]; then
        "$0" build "$rfile" --rebuild || true
      else
        warn "Receita não encontrada para $pkg"
      fi
    else
      warn "Fornecedor desconhecido para $lib"
    fi
    pkg=""
  done <"$TMPROOT/.missing.libs"
}

###############################################################################
# CLI
###############################################################################
usage() {
cat <<USAGE
pbuild – gerenciador POSIX para LFS

Uso:
  pbuild build <receita.pbuild> [opções]
  pbuild install <pacote.tar.{xz,gz,bz2}>
  pbuild remove <pkgname>
  pbuild info <pkgname>
  pbuild search <termo>
  pbuild revdep [--fix]

Opções gerais:
  --repo DIR         (default: $REPO)
  --sources DIR      (default: $SOURCES)
  --registro DIR     (default: $REGISTRO)
  --pkgout DIR       (default: $PKGOUT)
  --tmp DIR          (default: $TMPROOT)
  --jobs N|auto      (default: $JOBS)
  --strip yes|no     (default: $STRIP)
  --color auto|always|never (default: $COLOR)
  --rebuild          (ignora caches e recompila)

Exemplos Toolchain:
  Estrutura de receitas: \$REPO/base/gcc-12.0/{gcc-pass1.pbuild,gcc-12.0.pbuild}

USAGE
}

CMD=${1:-}
[ -n "$CMD" ] || { usage; exit 1; }
shift || true

REBUILD=no

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO=$2; shift 2;;
    --sources) SOURCES=$2; shift 2;;
    --registro) REGISTRO=$2; shift 2;;
    --pkgout) PKGOUT=$2; shift 2;;
    --tmp) TMPROOT=$2; shift 2;;
    --jobs) JOBS=$2; shift 2;;
    --strip) STRIP=$2; shift 2;;
    --color) COLOR=$2; shift 2;;
    --rebuild) REBUILD=yes; shift;;
    -h|--help) usage; exit 0;;
    *) set -- "$@"; break;;
  esac
done

case "$CMD" in
  build)
    RECIPE=${1:-}; [ -n "$RECIPE" ] || { err "Informe a receita"; exit 1; }
    _do_build "$RECIPE"
    ;;
  install)
    PKGFILE=${1:-}; [ -n "$PKGFILE" ] || { err "Informe o arquivo do pacote"; exit 1; }
    _install_pkg "$PKGFILE"
    ;;
  remove)
    PKG=${1:-}; [ -n "$PKG" ] || { err "Informe o nome do pacote"; exit 1; }
    remove_pkg "$PKG"
    ;;
  info)
    PKG=${1:-}; [ -n "$PKG" ] || { err "Informe o nome do pacote"; exit 1; }
    info_pkg "$PKG"
    ;;
  search)
    TERM=${1:-}; [ -n "$TERM" ] || { err "Informe o termo"; exit 1; }
    search_recipes "$TERM"
    ;;
  revdep)
    FIX=${1:-}
    revdep_check
    [ "$FIX" = "--fix" ] && revdep_fix || true
    ;;
  *) usage; exit 1;;
 esac

exit 0

################################################################################
# Abaixo: EXEMPLOS DE RECEITAS
################################################################################
# Salve como: $REPO/base/man-db-2.0.pbuild
#
# pkgname=[man-db]
# pkgver=[2.0]
# pkgurl=[https://example.org/releases/man-db-2.0.tar.xz]
# md5sum=[bdfrttgg....]
# build=[./configure --prefix=/usr --sysconfdir=/etc]
# check=[make check]
# install=[make install]
#
# Salve como: $REPO/base/gcc-12.0/gcc-pass1.pbuild
# pkgname=[gcc-pass1]
# pkgver=[12.0]
# pkgurl=[https://ftp.gnu.org/gnu/gcc/gcc-12.0/gcc-12.0.tar.xz]
# build=[./configure --prefix=/usr --disable-nls]
# install=[make install]
#
# E ao lado da receita, você pode manter o diretório de fontes/patches ou usar $SOURCES compartilhado.
