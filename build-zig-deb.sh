#!/usr/bin/env bash
set -euo pipefail

VERSION="0.17.1"
ARCH="amd64"            # Change to "arm64" for aarch64
ZIG_ARCH="x86_64"       # Change to "aarch64" for arm64
MAINTAINER="Your Name <you@example.com>"

TARBALL="zig-${ZIG_ARCH}-linux-${VERSION}.tar.xz"
URL="https://ziglang.org/download/${VERSION}/${TARBALL}"
EXTRACT_DIR="zig-${ZIG_ARCH}-linux-${VERSION}"
STAGE="zig_${VERSION}_${ARCH}"
INSTALL_ROOT="/opt/zig"
BIN_LINK="/usr/local/bin/zig"

download_fresh() {
  echo "Downloading ${URL}..."
  rm -f "${TARBALL}"
  curl -fL --retry 3 --retry-delay 2 --progress-bar -o "${TARBALL}" "${URL}"
}

# 1. Reuse existing complete tarball if present; otherwise resume or download
if [ -s "${TARBALL}" ] && xz -t "${TARBALL}" 2>/dev/null; then
  echo "Using complete local ${TARBALL} from current directory."
elif [ -s "${HOME}/Downloads/${TARBALL}" ] && xz -t "${HOME}/Downloads/${TARBALL}" 2>/dev/null; then
  echo "Using complete local ${TARBALL} from ${HOME}/Downloads."
  cp "${HOME}/Downloads/${TARBALL}" "${TARBALL}"
else
  if [ -s "${TARBALL}" ]; then
    echo "Existing ${TARBALL} is incomplete or corrupted; attempting to resume download..."
    if ! curl -fL --retry 3 --retry-delay 2 --progress-bar -C - -o "${TARBALL}" "${URL}" || ! xz -t "${TARBALL}" 2>/dev/null; then
      echo "Resume did not yield a valid archive; downloading fresh copy..."
      download_fresh
    fi
  else
    download_fresh
  fi
  xz -t "${TARBALL}"
fi

rm -rf "${EXTRACT_DIR}" "${STAGE}"
tar -xf "${TARBALL}"

# 2. Create Debian staging layout (only /opt/zig is staged)
mkdir -p "${STAGE}/DEBIAN"
mkdir -p "${STAGE}${INSTALL_ROOT}"

# Copy compiler binary and its required lib/ directory
cp "${EXTRACT_DIR}/zig" "${STAGE}${INSTALL_ROOT}/zig"
cp -r "${EXTRACT_DIR}/lib" "${STAGE}${INSTALL_ROOT}/lib"

# Create symlink on configure (and remove it on removal/purge)
cat <<EOF > "${STAGE}/DEBIAN/postinst"
#!/usr/bin/env bash
set -e
if [ "\$1" = "configure" ]; then
  mkdir -p "$(dirname "${BIN_LINK}")"
  ln -sf "${INSTALL_ROOT}/zig" "${BIN_LINK}"
fi
EOF

cat <<EOF > "${STAGE}/DEBIAN/postrm"
#!/usr/bin/env bash
set -e
case "\$1" in
  remove|purge|abort-install|abort-upgrade|disappear)
    rm -f "${BIN_LINK}"
    ;;
esac
EOF

# 3. Calculate exact Installed-Size in KiB and generate DEBIAN/control
INSTALLED_SIZE=$(du -sk "${STAGE}/opt" 2>/dev/null | awk '{s+=$1} END {print s}')

cat <<EOF > "${STAGE}/DEBIAN/control"
Package: zig
Version: ${VERSION}
Section: devel
Priority: optional
Architecture: ${ARCH}
Maintainer: ${MAINTAINER}
Installed-Size: ${INSTALLED_SIZE}
Description: Zig programming language compiler and toolchain
 Precompiled official binary release of the Zig ${VERSION} compiler,
 build system, and standard library.
EOF

# 4. Normalize permissions:
#    - Directories: 0755 (rwxr-xr-x)
#    - Regular files: 0644 (rw-r--r--)
#    - Zig binary & maintainer scripts: 0755 (rwxr-xr-x)
find "${STAGE}" -type d -exec chmod 0755 {} +
find "${STAGE}" -type f -exec chmod 0644 {} +
chmod 0755 "${STAGE}${INSTALL_ROOT}/zig"
chmod 0755 "${STAGE}/DEBIAN/postinst" "${STAGE}/DEBIAN/postrm"

dpkg-deb --build --root-owner-group "${STAGE}"

echo "Built ${STAGE}.deb successfully."
echo "Checking directory entries in package:"
dpkg-deb --contents "${STAGE}.deb" | awk '$1 ~ /^d/'
