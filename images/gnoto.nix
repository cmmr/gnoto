# gnoto.nix - The gnoto image: every tool gnoto's own scripts and Nextflow run with.
#
# Builds with nix-build anywhere Nix runs, such as the nixos/nix image in Docker,
# which "test/testbed/testbed.sh image" uses. The result is an uncompressed
# docker-archive tarball, which apptainer build turns into a .sif:
#
#     nix-build --no-out-link images/gnoto.nix
#
# Holds no gnoto code: the launcher binds that in from the job's commit. Slurm,
# Apptainer and systemd stay on the host and are reached through host/helper.sh.
#
# Every version here is fixed by the nixpkgs revision, except Nextflow, which
# is the official dist file checked by hash.

let

  # nixos-26.05, the most recent stable branch, on 2026-11-05
  nixpkgs = builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/7dcdd87373d72e7a2173e4db02e20d3d7f495cfd.tar.gz";
    sha256 = "09f5ys7xly8gaip09yxpp1xawqm4dlzrjq0ib8x80y9wsdpnp2xl";
  };

  pkgs = import nixpkgs { system = "x86_64-linux"; };

  # JDK 25 is the newest JDK in nixos-26.05. Nextflow 26.10 supports 17 to 26.
  jdk = pkgs.jdk25_headless;

  # The JDK's own bin is a symlink, which the image's /bin doesn't take in
  jdkBin = pkgs.runCommand "jdk-bin" { } ''
    mkdir -p $out/bin
    ln -s ${jdk.home}/bin/* $out/bin/
  '';

  nextflowVersion = "26.10.5";

  # nixpkgs carries Nextflow 25.10.2. The dist file is the launcher with the
  # whole framework appended, so it never downloads one into NXF_HOME. It's
  # kept byte-identical and run through a wrapper. It finds the framework in
  # itself through command -v "$0", which needs it executable: otherwise it
  # tries ./$0 and then downloads the framework.
  nextflowDist = pkgs.fetchurl {
    url = "https://github.com/nextflow-io/nextflow/releases/download/v${nextflowVersion}/nextflow-${nextflowVersion}-dist";
    hash = "sha256-sDADDAYEC/XxOsQjwxjRRslejR2C9QInmdyyRzi8zz4=";
  };

  nextflow = pkgs.runCommand "nextflow-${nextflowVersion}" { } ''
    mkdir -p $out/bin $out/share/nextflow
    install -m 555 ${nextflowDist} $out/share/nextflow/nextflow-${nextflowVersion}-dist
    cat > $out/bin/nextflow <<EOF
    #!${pkgs.bash}/bin/bash
    exec ${pkgs.bash}/bin/bash $out/share/nextflow/nextflow-${nextflowVersion}-dist "\$@"
    EOF
    chmod +x $out/bin/nextflow
  '';

  # globus-cli 3.41.0 pins jmespath 1.0.1, and nixos-26.05 has 1.1.0, so it
  # doesn't build there as it stands
  globus-cli = pkgs.globus-cli.overridePythonAttrs (old: {
    pythonRelaxDeps = (old.pythonRelaxDeps or [ ]) ++ [ "jmespath" ];
  });

in

pkgs.dockerTools.buildLayeredImage {
  name = "gnoto";

  # Apptainer's docker-archive reader rejects a gzipped archive, with a
  # misleading "gzip: invalid header".
  compressor = "none";

  contents = [ globus-cli jdkBin nextflow ] ++ (with pkgs; [
    bashInteractive
    coreutils
    gawk
    gnused
    gnugrep
    findutils
    diffutils
    gnutar
    gzip
    pigz
    lbzip2
    zip
    unzip
    procps
    jq
    yq-go
    curl
    openssl
    util-linux
    git
    awscli2
    dockerTools.binSh
    dockerTools.usrBinEnv
    dockerTools.caCertificates
  ]);

  # Real files rather than dockerTools.fakeNss, whose symlinks into the store
  # Apptainer can't follow. Apptainer appends the calling user to these, and
  # without that Java's user.name is "?", which Nextflow passes to squeue -u.
  extraCommands = ''
    mkdir -m 1777 tmp
    mkdir -p etc
    printf '%s\n' 'root:x:0:0:root:/root:/bin/sh' 'nobody:x:65534:65534:nobody:/var/empty:/bin/sh' > etc/passwd
    printf '%s\n' 'root:x:0:' 'nobody:x:65534:' > etc/group
    printf '%s\n' 'passwd: files' 'group: files' 'hosts: files dns' > etc/nsswitch.conf
  '';

  config = {
    Env = [
      "PATH=/bin"
      "LC_ALL=C.UTF-8"
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
      "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
      "JAVA_HOME=${jdk.home}"
      "NXF_DISABLE_CHECK_LATEST=true"
    ];
  };
}
