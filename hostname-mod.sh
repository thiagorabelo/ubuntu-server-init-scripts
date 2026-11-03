#!/bin/bash
#
# Prepara uma VM clonada (Clone Linkado no VirtualBox) para conviver na rede
# com a VM base: troca o hostname e gera um novo machine-id.
#
# Por que o machine-id? No Ubuntu Server, o systemd-networkd se identifica
# para o servidor DHCP com um ID derivado do machine-id, e não do MAC. Por
# isso, mesmo com MACs diferentes, os clones recebem o mesmo IP da VM base.
# Com um machine-id novo, a VM passa a receber outro IP após reiniciar.

# Interrompe o script no primeiro erro (-e), ao usar variável não definida (-u)
# ou quando qualquer comando de um pipe falhar (pipefail).
set -euo pipefail


#################################################################
# Configurações
#################################################################

readonly HOSTS_FILE="/etc/hosts"
readonly MACHINE_ID_FILE="/etc/machine-id"
readonly DBUS_MACHINE_ID_FILE="/var/lib/dbus/machine-id"

readonly REBOOT_DELAY_SECONDS=3

# Preenchidas por parse_args.
NEW_HOSTNAME=""
DO_REBOOT=false


#################################################################
# Funções auxiliares
#################################################################

function print_help {
    cat <<EOF
Troca o hostname e gera um novo machine-id (para a VM receber um novo IP).

Uso:
    sudo ./hostname-mod.sh NOVO_HOSTNAME [OPÇÕES]

Argumentos:

  NOVO_HOSTNAME     Novo nome da máquina. Use apenas letras, números e
                    hífen (até 63 caracteres, sem hífen no início ou no fim).

Opções:

  --reboot          Reinicia a máquina ao final (após ${REBOOT_DELAY_SECONDS} segundos,
                    com possibilidade de cancelar com Ctrl+C).
  --help            Exibe esta mensagem e sai.

EOF
}


function log {
    echo "==> $*"
}


function die {
    echo "Erro: $*" >&2
    exit 1
}


function backup_file {
    # Guarda uma cópia do arquivo original antes de alterá-lo. Se o backup já
    # existir, não sobrescreve: assim o .bak sempre guarda a versão original,
    # mesmo que o script seja executado várias vezes.

    local file="$1"
    if [[ ! -e "${file}.bak" ]]
    then
        cp -a "${file}" "${file}.bak"
        log "Backup criado: ${file}.bak"
    fi
}


function is_valid_hostname {
    # Segue a regra da RFC 1123 para um nome simples (sem domínio):
    #   ^[a-zA-Z0-9]           começa com letra ou número;
    #   [a-zA-Z0-9-]{0,61}     no meio, até 61 letras, números ou hífens;
    #   [a-zA-Z0-9]$           termina com letra ou número.
    # O trecho do meio e o final são opcionais (?), para aceitar nomes de um
    # único caractere. No total, o nome tem de 1 a 63 caracteres.

    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]
}


#################################################################
# Tarefas
#################################################################

function change_hostname {
    local new_hostname="$1"

    # Além de gravar o /etc/hostname, o hostnamectl aplica o nome na hora.
    hostnamectl set-hostname "${new_hostname}"
}


function update_etc_hosts {
    local new_hostname="$1"
    backup_file "${HOSTS_FILE}"

    # O Ubuntu registra o próprio hostname na linha "127.0.1.1". Só essa linha
    # é alterada, para não mexer em outros nomes que contenham o antigo
    # (ex.: trocar "base" não deve afetar "base-db").
    #
    # O "\." casa com um ponto literal (sem a barra, o ponto casaria com
    # qualquer caractere) e o [[:space:]] exige espaço ou tab após o IP.
    if grep -qE '^127\.0\.1\.1[[:space:]]' "${HOSTS_FILE}"
    then
        sed -i -E "s/^127\.0\.1\.1[[:space:]].*$/127.0.1.1\t${new_hostname}/" "${HOSTS_FILE}"
    else
        printf '127.0.1.1\t%s\n' "${new_hostname}" >> "${HOSTS_FILE}"
    fi
}


function regenerate_machine_id {
    # Sem o arquivo, o systemd-machine-id-setup gera um ID novo e aleatório.
    rm -f "${MACHINE_ID_FILE}"
    systemd-machine-id-setup

    # O D-Bus mantém a própria cópia do machine-id. No Ubuntu ela costuma ser
    # um link para /etc/machine-id; garante isso para que a cópia antiga (da
    # VM base) não continue em uso.
    if [[ -d "$(dirname "${DBUS_MACHINE_ID_FILE}")" ]]
    then
        ln -sf "${MACHINE_ID_FILE}" "${DBUS_MACHINE_ID_FILE}"
    fi
}


function reboot_with_countdown {
    # Ctrl+C durante a contagem cancela só o reinício: as alterações já
    # feitas continuam valendo.
    trap 'echo; log "Reinício cancelado. Reinicie depois para receber o novo IP."; exit 0' INT

    local seconds
    for (( seconds = REBOOT_DELAY_SECONDS; seconds > 0; seconds-- ))
    do
        # O "\r" volta ao início da linha, para a contagem se atualizar no lugar.
        printf '\r==> Reiniciando em %d segundo(s)... (Ctrl+C para cancelar) ' "${seconds}"
        sleep 1
    done
    echo

    trap - INT
    systemctl reboot
}


#################################################################
# Execução
#################################################################

function parse_args {
    # Apenas registra o que foi pedido. A execução das tarefas fica no main.

    local arg
    for arg in "$@"
    do
        case "${arg}" in
            --reboot)
                DO_REBOOT=true
                ;;
            --help)
                print_help
                exit 0
                ;;
            -*)
                echo "Opção desconhecida: ${arg}" >&2
                echo >&2
                print_help >&2
                exit 1
                ;;
            *)
                if [[ -n "${NEW_HOSTNAME}" ]]
                then
                    die "informe apenas um hostname (recebidos: '${NEW_HOSTNAME}' e '${arg}')."
                fi
                NEW_HOSTNAME="${arg}"
                ;;
        esac
    done

    if [[ -z "${NEW_HOSTNAME}" ]]
    then
        echo "Informe o novo hostname." >&2
        echo >&2
        print_help >&2
        exit 1
    fi
}


function main {
    parse_args "$@"

    if ! is_valid_hostname "${NEW_HOSTNAME}"
    then
        die "hostname inválido: '${NEW_HOSTNAME}' (veja --help)."
    fi

    if [[ "$(id -ru)" != "0" ]]
    then
        die "execute este script com privilégios de root (sudo)."
    fi

    local current_hostname
    current_hostname="$(hostname)"

    if [[ "${current_hostname}" == "${NEW_HOSTNAME}" ]]
    then
        log "O hostname já é '${NEW_HOSTNAME}'; mantendo"
    else
        log "Renomeando '${current_hostname}' para '${NEW_HOSTNAME}'"
        change_hostname "${NEW_HOSTNAME}"
    fi

    log "Atualizando ${HOSTS_FILE}"
    update_etc_hosts "${NEW_HOSTNAME}"

    log "Gerando novo machine-id"
    regenerate_machine_id

    if [[ "${DO_REBOOT}" == true ]]
    then
        reboot_with_countdown
    else
        log "Concluído. Reinicie a máquina para receber o novo IP."
    fi
}


main "$@"
