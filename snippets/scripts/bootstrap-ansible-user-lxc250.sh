#!/usr/bin/env bash
#
# Bootstrap the `ansible` user on lxc250, the Ansible control node.
#
# Why this is a script and not `bootstrap-ansible-user.yml`: that playbook
# connects as `remote_user: root` over SSH, and lxc250's own sshd refuses
# root logins (ssh_hardening). The control node cannot bootstrap itself the
# way it bootstraps every other node, so this one runs locally as root.
#
# Run as root INSIDE the container.
# Idempotent: safe to run more than once, changes nothing on a second run.

set -euo pipefail

USER_NAME=ansible
HOME_DIR="/home/${USER_NAME}"
PUBKEY_SRC=/home/devops/.ssh/id_ed25519.pub
SUDOERS=/etc/sudoers.d/${USER_NAME}

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
[ -r "$PUBKEY_SRC" ] || { echo "public key not readable: $PUBKEY_SRC" >&2; exit 1; }

# --- 1. the account ---------------------------------------------------------
if id -u "$USER_NAME" >/dev/null 2>&1; then
    echo "user ${USER_NAME}: already present, unchanged"
else
    useradd --create-home --shell /bin/bash "$USER_NAME"
    echo "user ${USER_NAME}: created"
fi

# --- 2. the SSH key ---------------------------------------------------------
install -d -o "$USER_NAME" -g "$USER_NAME" -m 0700 "${HOME_DIR}/.ssh"

AUTH="${HOME_DIR}/.ssh/authorized_keys"
if [ ! -e "$AUTH" ]; then
    install -o "$USER_NAME" -g "$USER_NAME" -m 0600 /dev/null "$AUTH"
fi

KEY_LINE="$(cat "$PUBKEY_SRC")"
if grep -qxF "$KEY_LINE" "$AUTH"; then
    echo "authorized_keys: key already present, unchanged"
else
    printf '%s\n' "$KEY_LINE" >> "$AUTH"
    echo "authorized_keys: key appended"
fi
chown "${USER_NAME}:${USER_NAME}" "$AUTH"
chmod 0600 "$AUTH"

# --- 3. sudo ----------------------------------------------------------------
if ! command -v sudo >/dev/null 2>&1; then
    echo "sudo: not installed, installing"
    DEBIAN_FRONTEND=noninteractive apt-get install -y sudo
fi

TMP_SUDOERS="$(mktemp)"
trap 'rm -f "$TMP_SUDOERS"' EXIT
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$USER_NAME" > "$TMP_SUDOERS"

if visudo -csf "$TMP_SUDOERS" >/dev/null; then
    if [ -f "$SUDOERS" ] && cmp -s "$TMP_SUDOERS" "$SUDOERS"; then
        echo "sudoers: already correct, unchanged"
    else
        install -o root -g root -m 0440 "$TMP_SUDOERS" "$SUDOERS"
        echo "sudoers: written to ${SUDOERS}"
    fi
else
    echo "sudoers: syntax check FAILED, nothing written" >&2
    exit 1
fi

# --- 4. verification --------------------------------------------------------
echo
echo "=== verification ==="
id "$USER_NAME"
stat -c '%n %U:%G %a' "${HOME_DIR}/.ssh" "$AUTH" "$SUDOERS"
sudo -n -l -U "$USER_NAME" | tail -n 3
