#!/bin/sh

PJAILNAME="iocage"
PPORTS="iocports"
ZROOT="/usr/local/poudriere"
POUDCONFDIR="/usr/local/etc"
PORTS_GIT_URL="https://github.com/freenas/iocage-ports.git"
PORTS_GIT_BRANCH="master"
JAILVER="11.2-RELEASE"
PPKGDIR="${ZROOT}/data/packages/${PJAILNAME}-${PPORTS}"
PPORTSDIR="${ZROOT}/ports/${PPORTS}"

mk_poud_config()
{

# Figure out ZFS settings
ZPOOL="data"

cat >${POUDCONFDIR}/poudriere.conf << EOF
ZPOOL=$ZPOOL
FREEBSD_HOST=file://${DISTDIR}
BUILD_AS_NON_ROOT=no
RESOLV_CONF=/etc/resolv.conf
BASEFS=$ZROOT
USE_PORTLINT=no
USE_TMPFS=${TMPWRK}
USE_TMPFS=all
ALLOW_MAKE_JOBS=yes
DISTFILES_CACHE=/usr/ports/distfiles
CHECK_CHANGED_OPTIONS=verbose
CHECK_CHANGED_DEPS=yes
PARALLEL_JOBS=${BUILDERS}
WRKDIR_ARCHIVE_FORMAT=txz
ALLOW_MAKE_JOBS_PACKAGES="pkg ccache py* llvm* libreoffice* apache-openoffice* webkit* firefox* chrom* gcc* qt5-*"
MAX_EXECUTION_TIME=86400
NOHANG_TIME=12600
ATOMIC_PACKAGE_REPOSITORY=no
PKG_REPO_FROM_HOST=yes
BUILDER_HOSTNAME=builds.trueos.org
PRIORITY_BOOST="pypy openoffice* paraview webkit* llvm*"
GIT_URL=${PORTS_GIT_URL}
FREEBSD_HOST=https://download.freebsd.org
USE_COLORS=yes
NOLINUX=yes
EOF

  # Check if we have a ccache dir to be used
  if [ -e "/ccache" ] ; then
    echo "CCACHE_DIR=/ccache" >> ${POUDCONFDIR}/poudriere.conf
  fi

  # Set any port make options
  if [ ! -d "${POUDCONFDIR}/poudriere.d" ] ; then
    mkdir -p ${POUDCONFDIR}/poudriere.d
  fi
  cp conf/port-options.conf ${POUDCONFDIR}/poudriere.d/${PJAILNAME}-make.conf
  if [ $? -ne 0 ] ; then
	  exit 1
  fi

}

do_portsnap()
{
  mk_poud_config

  # Kill any previous running jail
  poudriere -e ${POUDCONFDIR} jail -k -j ${PJAILNAME} -p ${PPORTS} 2>/dev/null

  echo "Removing old ports dir..."
  poudriere -e ${POUDCONFDIR} ports -p ${PPORTS} -d
  rm -rf /poud/ports/${PPORTS}

  echo "Pulling ports from ${PORTS_GIT_URL} - ${PORTS_GIT_BRANCH}"
  poudriere -e ${POUDCONFDIR} ports -c -p ${PPORTS} -B ${PORTS_GIT_BRANCH} -m git
  if [ $? -ne 0 ] ; then
    exit_err "Failed pulling ports tree"
  fi

  # Adjust the minecraft-server Makefile
  cat ${PPORTSDIR}/games/minecraft-server/Makefile \
	  | grep -v "^LICENSE" > ${PPORTSDIR}/games/minecraft-server/Makefile.new
  mv ${PPORTSDIR}/games/minecraft-server/Makefile.new \
	  ${PPORTSDIR}/games/minecraft-server/Makefile
}

update_poud_world()
{
  echo "Removing old jail - $PJAILNAME"
  poudriere -e ${POUDCONFDIR} jail -d -j $PJAILNAME
  rm -rf /poud/jails/$PJAILNAME

  echo "Creating new jail: $PJAILNAME - $JAILVER"
  poudriere -e ${POUDCONFDIR} jail -c -j $PJAILNAME -v $JAILVER -m http
  if [ $? -ne 0 ] ; then
    exit_err "Failed creating poudriere jail"
  fi
}

# Kill any previous running jail
poudriere -e ${POUDCONFDIR} jail -k -j ${PJAILNAME} -p ${PPORTS} 2>/dev/null

# Cleanup old packages?
POUDFLAGS=""
if [ "$WIPEPOUDRIERE" = "true" ] ; then
  POUDFLAGS="-c"
fi

# Create the poud config
mk_poud_config

# Extract the world for this poud build
update_poud_world

# Update the ports tree
do_portsnap

# Start the build
poudriere -e ${POUDCONFDIR} bulk ${POUDFLAGS} -j ${PJAILNAME} -p ${PPORTS} -f $(pwd)/conf/iocage-ports
if [ $? -ne 0 ] ; then
   echo "Failed poudriere build..."
   exit 1
fi

# Signing script
if [ -n "$SIGNING_PRIV_KEY" ] ; then
  echo "Signing the packages"
  cat > /tmp/sign.sh << EOF
#!/bin/sh
read -t 2 sum
[ -z "$sum" ] && exit 1
echo SIGNATURE
echo -n $sum | /usr/bin/openssl dgst -sign "${SIGNING_PRIV_KEY}" -sha256 -binary
echo
echo CERT
cat "${SIGNING_PUB_KEY}"
echo END
EOF
  chmod 755 /tmp/sign.sh

  cd ${PPKGDIR}
  if [ $? -ne 0 ] ; then exit 1 ; fi
  pkg repo . signing_command: /tmp/sign.sh
  if [ $? -ne 0 ] ; then exit 1 ; fi
fi

echo "Build complete!"
exit 0
