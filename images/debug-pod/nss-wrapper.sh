# Sourced from /etc/bash.bashrc (kubectl exec bash) and /etc/profile (login shells).
# OpenShift runs pods with a random UID that has no /etc/passwd entry, which
# breaks whoami, ssh and the bash prompt. The root filesystem is read-only so
# /etc/passwd can't be patched; instead use nss_wrapper with passwd/group
# files in /tmp that include the current UID/GID.
if ! getent passwd "$(id -u)" >/dev/null 2>&1 && [ -w /tmp ]; then
  export NSS_WRAPPER_PASSWD=/tmp/.nss_passwd
  export NSS_WRAPPER_GROUP=/tmp/.nss_group
  if [ ! -s "${NSS_WRAPPER_PASSWD}" ]; then
    { cat /etc/passwd
      echo "debug:x:$(id -u):$(id -g):debug:${HOME:-/tmp}:/bin/bash"
    } > "${NSS_WRAPPER_PASSWD}"
    cp /etc/group "${NSS_WRAPPER_GROUP}"
    getent group "$(id -g)" >/dev/null 2>&1 || \
      echo "debug:x:$(id -g):" >> "${NSS_WRAPPER_GROUP}"
  fi
  export LD_PRELOAD=libnss_wrapper.so
fi
