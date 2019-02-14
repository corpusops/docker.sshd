#!/usr/bin/env bash
set -e
SDEBUG=${SSHD_SDEBUG-}
export TZ="${TZ:-Europe/Paris}"
echo $TZ > /etc/timezone
cp -f /usr/share/zoneinfo/$TZ /etc/localtime

export MAX_RETRY=${MAX_RETRY:-6}
if [[ -n "$SSHD_SDEBUG" ]];then
    set -x
fi

log() { echo "$@">&2; }
vv() { log "$@"; "$@"; }
SSH_CONFIG=/etc/ssh/sshd_config
touch $SSH_CONFIG
if [ -e "$SSH_CONFIG".in ];then
    vv frep $SSH_CONFIG.in:$SSH_CONFIG --overwrite
fi

for i in /etc/authorized_keys /etc/ssh/keys;do
    if [ -d $i.in ];then
        rsync -azv $i.in/ $i/
        chmod -Rf 700 $i
        chown -Rf root:root $i
    fi
done

for i in /etc/authorized_keys;do
    chmod 0640 $i/*
done

# Copy default config from cache
if [ ! "$(ls -A /etc/ssh)" ]; then
   cp -a /etc/ssh.cache/* /etc/ssh/
fi

print_fingerprints() {
    local BASE_DIR=${1-'/etc/ssh'}
    for item in dsa rsa ecdsa ed25519;do
        echo ">>> Fingerprints for ${item} host key"
        ssh-keygen -E md5 -lf ${BASE_DIR}/ssh_host_${item}_key
        ssh-keygen -E sha256 -lf ${BASE_DIR}/ssh_host_${item}_key
        ssh-keygen -E sha512 -lf ${BASE_DIR}/ssh_host_${item}_key
    done
}

# Generate Host keys, if required
if ls /etc/ssh/keys/ssh_host_* 1> /dev/null 2>&1; then
    echo ">> Host keys in keys directory"
    print_fingerprints /etc/ssh/keys
elif ls /etc/ssh/ssh_host_* 1> /dev/null 2>&1; then
    echo ">> Host keys exist in default location"
    # Don't do anything
    print_fingerprints
else
    echo ">> Generating new host keys"
    mkdir -p /etc/ssh/keys
    ssh-keygen -A
    mv /etc/ssh/ssh_host_* /etc/ssh/keys/
    print_fingerprints /etc/ssh/keys
fi

# Fix permissions, if writable
if [ -w ~/.ssh ]; then
    chown root:root ~/.ssh && chmod 700 ~/.ssh/
fi
if [ -w ~/.ssh/authorized_keys ]; then
    chown root:root ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
fi
if [ -w /etc/authorized_keys ]; then
    chown root:root /etc/authorized_keys
    chmod 755 /etc/authorized_keys
    find /etc/authorized_keys/ -type f -exec chmod 644 {} \;
fi
# Add users if SSH_USERS=user:uid:gid set
if [ -n "${SSH_USERS}" ]; then
    USERS=$(echo $SSH_USERS | tr "," "\n")
    for U in $USERS; do
        IFS=':' read -ra UA <<< "$U"
        _NAME=${UA[0]}
        _UID=${UA[1]}
        _GID=${UA[2]}

        echo ">> Adding user ${_NAME} with uid: ${_UID}, gid: ${_GID}."
        if [ ! -e "/etc/authorized_keys/${_NAME}" ]; then
            echo "WARNING: No SSH authorized_keys found for ${_NAME}!"
        fi
        getent group ${_NAME} >/dev/null 2>&1 || addgroup -g ${_GID} ${_NAME}
        getent passwd ${_NAME} >/dev/null 2>&1 || adduser -D -u ${_UID} -G ${_NAME} -s '' ${_NAME}
        passwd -u ${_NAME} || true
    done
else
    # Warn if no authorized_keys
    if [ ! -e ~/.ssh/authorized_keys ] && [ ! $(ls -A /etc/authorized_keys) ]; then
      echo "WARNING: No SSH authorized_keys found!"
    fi
fi

# Update MOTD
if [ -v MOTD ]; then
    echo -e "$MOTD" > /etc/motd
fi

cp -rfv /fail2ban/* /etc/fail2ban
frep --overwrite /fail2ban/jail.d/alpine-ssh.conf:/etc/fail2ban/jail.d/alpine-ssh.conf
exec /bin/supervisord.sh
