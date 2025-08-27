#!/bin/sh
# pbuild - Gerenciador de pacotes para LFS
# Autor: Você :)
# POSIX compliant

# === VARIÁVEIS GLOBAIS ===
PBUILD_ROOT="/tmp/pbuild"
PBUILD_REPO="${REPO:-/opt/pbuild/repo}"     
PBUILD_SOURCES="${SOURCES:-/opt/pbuild/sources}"
PBUILD_REGISTRO="${REGISTRO:-/opt/pbuild/registro}"
PBUILD_LOGDIR="$PBUILD_ROOT/logs"
PBUILD_PKGDIR="$PBUILD_SOURCES/packages"
PBUILD_HOOKS="$PBUILD_REPO/hooks"

mkdir -p "$PBUILD_ROOT" "$PBUILD_SOURCES" "$PBUILD_REGISTRO" "$PBUILD_LOGDIR" "$PBUILD_PKGDIR"

# === CORES ===
red="\033[1;31m"
green="\033[1;32m"
yellow="\033[1;33m"
blue="\033[1;34m"
reset="\033[0m"

# === FUNÇÃO DE SPINNER ===
spinner() {
    pid="$1"
    spin='-\|/'
    i=0
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r[%s] " "${spin:$i:1}"
        sleep 0.1
    done
    printf "\r    \r"
}

# === FUNÇÕES DE LOG ===
log()   { printf "${green}[+]${reset} %s\n" "$*"; }
warn()  { printf "${yellow}[!]${reset} %s\n" "$*"; }
error() { printf "${red}[-]${reset} %s\n" "$*"; exit 1; }

# === FUNÇÃO: CARREGAR RECEITA ===
load_recipe() {
    recipe="$1"
    [ ! -f "$recipe" ] && error "Receita $recipe não encontrada."
    . "$recipe"
    : "${pkgname:?}" "${pkgver:?}" "${pkgdir:?}" "${pkgurl:?}" || error "Receita inválida"
    : "${build:?}" "${install:?}" || error "Receita deve definir 'build' e 'install'"
}

# === FUNÇÃO: DOWNLOAD ===
download() {
    case "$pkgurl" in
        git+*)
            url="${pkgurl#git+}"
            log "Clonando repositório $url"
            cd "$PBUILD_SOURCES" || exit 1
            [ -d "$pkgdir" ] || git clone "$url" "$pkgdir" 2>&1 | tee "$PBUILD_LOGDIR/$pkgname-download.log" &
            pid=$!
            spinner $pid
            ;;
        http*|ftp*)
            file=$(basename "$pkgurl")
            log "Baixando $pkgurl"
            cd "$PBUILD_SOURCES" || exit 1
            [ -f "$file" ] || curl -L "$pkgurl" -o "$file" 2>&1 | tee "$PBUILD_LOGDIR/$pkgname-download.log" &
            pid=$!
            spinner $pid
            ;;
        *)
            error "URL não reconhecida: $pkgurl"
            ;;
    esac
}

# === FUNÇÃO: EXTRAIR ===
extract() {
    cd "$PBUILD_ROOT" || exit 1
    if [ -d "$PBUILD_SOURCES/$pkgdir/.git" ]; then
        log "Copiando repositório git $pkgdir"
        cp -r "$PBUILD_SOURCES/$pkgdir" .
        return
    fi

    src="$PBUILD_SOURCES/$(basename "$pkgurl")"
    log "Extraindo $src"
    case "$src" in
        *.tar.gz|*.tgz)   tar -xf "$src" ;;
        *.tar.xz)         tar -xf "$src" ;;
        *.tar.bz2)        tar -xf "$src" ;;
        *.zip)            unzip -q "$src" ;;
        *)
            error "Formato não suportado: $src"
            ;;
    esac
}

# === FUNÇÃO: PATCH ===
apply_patches() {
    [ -n "$patches" ] || return
    cd "$PBUILD_ROOT/$pkgdir" || exit 1
    for p in $patches; do
        log "Aplicando patch $p"
        patch -p1 < "$PBUILD_REPO/patches/$p" 2>&1 | tee -a "$PBUILD_LOGDIR/$pkgname-patch.log" &
        pid=$!
        spinner $pid
    done
}

# === FUNÇÃO: BUILD ===
build_pkg() {
    cd "$PBUILD_ROOT/$pkgdir" || error "Diretório $pkgdir não encontrado"
    log "Compilando $pkgname"
    sh -c "$build" 2>&1 | tee "$PBUILD_LOGDIR/$pkgname-build.log" &
    pid=$!
    spinner $pid
}

# === FUNÇÃO: CHECK ===
check() {
    [ -n "$check" ] || { warn "Sem testes definidos"; return; }
    cd "$PBUILD_ROOT/$pkgdir" || exit 1
    log "Testando $pkgname"
    sh -c "$check" 2>&1 | tee "$PBUILD_LOGDIR/$pkgname-check.log" &
    pid=$!
    spinner $pid
}

# === FUNÇÃO: INSTALL ===
install_pkg() {
    cd "$PBUILD_ROOT/$pkgdir" || exit 1
    DESTDIR="$PBUILD_ROOT/$pkgname-pkg"
    rm -rf "$DESTDIR"
    mkdir -p "$DESTDIR"
    log "Instalando em DESTDIR"
    DESTDIR="$DESTDIR" sh -c "$install" 2>&1 | tee "$PBUILD_LOGDIR/$pkgname-install.log" &
    pid=$!
    spinner $pid

    # Empacotamento
    pkgfile="$PBUILD_PKGDIR/${pkgname}-${pkgver}.tar.xz"
    log "Empacotando em $pkgfile"
    tar -C "$DESTDIR" -cJf "$pkgfile" . || error "Falha ao empacotar $pkgname"

    # Instalação real com fakeroot
    log "Instalando no sistema via fakeroot"
    fakeroot sh -c "tar -C / -xf $pkgfile" || error "Falha ao instalar $pkgname"

    # Registrar arquivos
    tar -tf "$pkgfile" | sed 's|^/||' > "$PBUILD_REGISTRO/${pkgname}.files"
    echo "$pkgname $pkgver" > "$PBUILD_REGISTRO/${pkgname}.info"

    log "$pkgname $pkgver instalado com sucesso"
}

# === FUNÇÃO: REMOVE ===
remove_pkg() {
    pkg="$1"
    filelist="$PBUILD_REGISTRO/${pkg}.files"
    [ -f "$filelist" ] || { warn "Pacote $pkg não encontrado"; return; }
    log "Removendo $pkg"
    while IFS= read -r f; do
        [ -e "/$f" ] && rm -rf "/$f"
    done < "$filelist"
    rm -f "$filelist" "$PBUILD_REGISTRO/${pkg}.info"
    log "$pkg removido com sucesso"

    # Executar hooks pós-remove, se existirem
    if [ -d "$PBUILD_HOOKS/post-remove.d" ]; then
        for hook in "$PBUILD_HOOKS/post-remove.d/"*; do
            [ -x "$hook" ] || continue
            log "Executando hook pós-remove: $hook"
            "$hook" "$pkg"
        done
    fi
}

# === FUNÇÃO: INFO ===
info_pkg() {
    pkg="$1"
    [ -f "$PBUILD_REGISTRO/${pkg}.info" ] && cat "$PBUILD_REGISTRO/${pkg}.info" || warn "Pacote $pkg não encontrado"
}

# === FUNÇÃO: SEARCH ===
search_pkg() {
    term="$1"
    find "$PBUILD_REPO" -type f -name "*.pbuild" | grep "$term"
}

# === DISPATCHER ===
case "$1" in
    install)
        recipe="$2"
        load_recipe "$recipe"
        download
        extract
        apply_patches
        build_pkg
        check
        install_pkg
        ;;
    build)
        recipe="$2"
        load_recipe "$recipe"
        download
        extract
        apply_patches
        build_pkg
        check
        log "Build concluído para $pkgname (não instalado)."
        ;;
    remove)
        remove_pkg "$2"
        ;;
    info)
        info_pkg "$2"
        ;;
    search)
        search_pkg "$2"
        ;;
    *)
        echo "Uso: pbuild {install <receita>|build <receita>|remove <pkg>|info <pkg>|search <termo>}"
        ;;
esac
