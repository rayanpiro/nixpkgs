{ lib
, stdenv
, fetchurl
, autoPatchelfHook
, openssl
, zlib
, lvm2  # LVM image backup and restore functions (optional)
, acl  # EXT2/EXT3/XFS ACL support (optional)
, gnugrep
, procps
, jdk8  # Java GUI (needed for `enableGui`)
, buildEnv
, makeWrapper
, enableGui ? false  # enables Java GUI `dsmj`
# path to `dsm.sys` configuration files
, dsmSysCli ? "/etc/tsm-client/cli.dsm.sys"
, dsmSysApi ? "/etc/tsm-client/api.dsm.sys"
}:


# For an explanation of optional packages
# (features provided by them, version limits), see
# https://www.ibm.com/support/pages/node/660813#Version%208.1


# IBM Tivoli Storage Manager Client uses a system-wide
# client system-options file `dsm.sys` and expects it
# to be located in a directory within the package.
# Note that the command line client and the API use
# different "dms.sys" files (located in different directories).
# Since these files contain settings to be altered by the
# admin user (e.g. TSM server name), we create symlinks
# in place of the files that the client attempts to open.
# Use the arguments `dsmSysCli` and `dsmSysApi` to
# provide the location of the configuration files for
# the command-line interface and the API, respectively.
#
# While the command-line interface contains wrappers
# that help the executables find the configuration file,
# packages that link against the API have to
# set the environment variable `DSMI_DIR` to
# point to this derivations `/dsmi_dir` directory symlink.
# Other environment variables might be necessary,
# depending on local configuration or usage; see:
# https://www.ibm.com/docs/en/spectrum-protect/8.1.13?topic=solaris-set-api-environment-variables


# The newest version of TSM client should be discoverable by
# going to the `downloadPage` (see `meta` below), then
# * find section "Client Service Release",
# * pick the latest version and follow the link
#   "IBM Spectrum Protect Client .. Downloads and READMEs"
# * in the table at the page's bottom, follow the
#   "HTTPS" link of the "Linux x86_64 Ubuntu client"
# * in the directory listing, pick the big `.tar` file
# (as of 2021-12-13)


let

  meta = {
    homepage = "https://www.ibm.com/products/data-protection-and-recovery";
    downloadPage = "https://www.ibm.com/support/pages/ibm-spectrum-protect-downloads-latest-fix-packs-and-interim-fixes";
    platforms = [ "x86_64-linux" ];
    license = lib.licenses.unfree;
    maintainers = [ lib.maintainers.yarny ];
    description = "IBM Spectrum Protect (Tivoli Storage Manager) CLI and API";
    longDescription = ''
      IBM Spectrum Protect (Tivoli Storage Manager) provides
      a single point of control for backup and recovery.
      This package contains the client software, that is,
      a command line client and linkable libraries.

      Note that the software requires a system-wide
      client system-options file (commonly named "dsm.sys").
      This package allows to use separate files for
      the command-line interface and for the linkable API.
      The location of those files can
      be provided as build parameters.
    '';
  };

  mkSrcUrl = version:
    let
      major = lib.versions.major version;
      minor = lib.versions.minor version;
      patch = lib.versions.patch version;
    in
      "https://public.dhe.ibm.com/storage/tivoli-storage-management/maintenance/client/v${major}r${minor}/Linux/LinuxX86_DEB/BA/v${major}${minor}${patch}/${version}-TIV-TSMBAC-LinuxX86_DEB.tar";

  unwrapped = stdenv.mkDerivation rec {
    name = "tsm-client-${version}-unwrapped";
    version = "8.1.13.0";
    src = fetchurl {
      url = mkSrcUrl version;
      sha256 = "0fy9c224g6rkrgd6ls01vs30bk9j9mlhf2x6akd11r7h8bib19zn";
    };
    inherit meta;

    nativeBuildInputs = [
      autoPatchelfHook
    ];
    buildInputs = [
      openssl
      stdenv.cc.cc
      zlib
    ];
    runtimeDependencies = [
      (lib.attrsets.getLib lvm2)
    ];
    sourceRoot = ".";

    postUnpack = ''
      for debfile in *.deb
      do
        ar -x "$debfile"
        tar --xz --extract --file=data.tar.xz
        rm data.tar.xz
      done
    '';

    installPhase = ''
      runHook preInstall
      mkdir --parents $out
      mv --target-directory=$out usr/* opt
      runHook postInstall
    '';

    # Fix relative symlinks after `/usr` was moved up one level
    preFixup = ''
      for link in $out/lib/* $out/bin/*
      do
        target=$(readlink "$link")
        if [ "$(cut -b -6 <<< "$target")" != "../../" ]
        then
          echo "cannot fix this symlink: $link -> $target"
          exit 1
        fi
        ln --symbolic --force --no-target-directory "$out/$(cut -b 7- <<< "$target")" "$link"
      done
    '';
  };

  binPath = lib.makeBinPath ([ acl gnugrep procps ]
    ++ lib.optional enableGui jdk8);

in

buildEnv {
  name = "tsm-client-${unwrapped.version}";
  inherit meta;
  passthru = { inherit unwrapped; };
  paths = [ unwrapped ];
  nativeBuildInputs = [ makeWrapper ];
  pathsToLink = [
    "/"
    "/bin"
    "/opt/tivoli/tsm/client/ba/bin"
    "/opt/tivoli/tsm/client/api/bin64"
  ];
  # * Provide top-level symlinks `dsm_dir` and `dsmi_dir`
  #   to the so-called "installation directories"
  # * Add symlinks to the "installation directories"
  #   that point to the `dsm.sys` configuration files
  # * Drop the Java GUI executable unless `enableGui` is set
  # * Create wrappers for the command-line interface to
  #   prepare `PATH` and `DSM_DIR` environment variables
  postBuild = ''
    ln --symbolic --no-target-directory opt/tivoli/tsm/client/ba/bin $out/dsm_dir
    ln --symbolic --no-target-directory opt/tivoli/tsm/client/api/bin64 $out/dsmi_dir
    ln --symbolic --no-target-directory "${dsmSysCli}" $out/dsm_dir/dsm.sys
    ln --symbolic --no-target-directory "${dsmSysApi}" $out/dsmi_dir/dsm.sys
    ${lib.optionalString (!enableGui) "rm $out/bin/dsmj"}
    for bin in $out/bin/*
    do
      target=$(readlink "$bin")
      rm "$bin"
      makeWrapper "$target" "$bin" \
        --prefix PATH : "$out/dsm_dir:${binPath}" \
        --set DSM_DIR $out/dsm_dir
    done
  '';
}
