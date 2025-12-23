{ config, pkgs, lib, modulesPath, ... }:

# For a  nice dark mode, still need to fix the font thing
let
  customCss = pkgs.fetchurl {
    url = "https://git.zx2c4.com/cgit.css";
    sha256 = "08xz7khasdvdxbmw07jsrnx18zhp6hm51xkfc3hlkavpvmxbs5qm";
  };
  hooks = ./hooks;
in {
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  boot.loader.grub.enable = true;
  boot.initrd.kernelModules = [ "dm-snapshot" ];

  environment.systemPackages = with pkgs; [
    vim
    ghostty.terminfo
    ruby
  ];

  services.tailscale.enable = true;

  networking.hostName = "cgit";
  time.timeZone = "UTC";

  users.users = {
    root = {
      hashedPassword = "$6$L3/5BO/M0YfGSKrt$TLbqESpa.ShaCzovng03RjNA97Pk4DIS.p7u0gIvbnGbsQHnsbD2DoNMhz4ePm.3PPbaaK2eiDgxsbjKRuyEG/";
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPkyXI1VJ7hDm2AA+ta5yKOTdqjFBfNWKUuhUKuGrMri"
      ];
    };

    git = {
      isNormalUser = true;
      home = "/home/git";
      shell = "${pkgs.git}/bin/git-shell";
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPkyXI1VJ7hDm2AA+ta5yKOTdqjFBfNWKUuhUKuGrMri"
      ];
    };
  };

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
  };

  networking.firewall.allowedTCPPorts = [ 22 80 443 ];

  # cgit configuration
  services.cgit.main = {
    enable = true;
    nginx.virtualHost = "git.sdko.net";
    scanPath = "/repos";
    settings = {
      root-title = "Git Repositories";
      root-desc = "Public git repositories";
      css = "/custom.css";
      logo = "/cgit.png";
      enable-index-owner = 0;
      enable-commit-graph = 1;
      enable-log-filecount = 1;
      enable-log-linecount = 1;
      max-repo-count = 50;
      cache-size = 1000;
      snapshots = "tar.gz tar.xz zip";
      clone-url = "https://git.sdko.net/$CGIT_REPO_URL git@git.sdko.net:$CGIT_REPO_URL";
      source-filter = "${pkgs.cgit}/lib/cgit/filters/syntax-highlighting.py";
      about-filter = "${pkgs.cgit}/lib/cgit/filters/about-formatting.sh";
    };
  };

  # nginx
  services.nginx = {
    enable = true;
    recommendedOptimisation = true;
    recommendedGzipSettings = true;
    serverTokens = false;
    package = pkgs.nginxMainline.override {
      modules = [ pkgs.nginxModules.moreheaders ];
    };
    commonHttpConfig = ''
      more_set_headers "Server: SDKO Git Server";
    '';
    virtualHosts."git.sdko.net" = {
      forceSSL = true;
      sslCertificate = "/etc/ssl/git.sdko.net/fullchain.cer";
      sslCertificateKey = "/etc/ssl/git.sdko.net/key.pem";
      locations."= /custom.css" = {
        alias = customCss;
      };
    };
  };

  # Create directory structure
  # /home/git/repos/{thing} - actual repos owned by git user
  # /repos/{repo} - symlinks for cgit to scan
  systemd.tmpfiles.rules = [
    "d /home/git 0755 git users -"
    "d /home/git/repos 0755 git users -"
    "d /home/git/.ssh 0700 git users -"
    "d /repos 0755 root root -"
    "d /etc/ssl/git.sdko.net 0750 root nginx -"
  ];

  # Initialize default repos if they don't exist
  systemd.services.init-git-repos = {
    description = "Initialize default git repositories";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      init_repo() {
        local name=$1
        local desc=$2
        if [ ! -d /home/git/repos/$name.git ]; then
          ${pkgs.git}/bin/git init --bare --initial-branch=master /home/git/repos/$name.git
          chown -R git:users /home/git/repos/$name.git
        fi
        echo "$desc" > /home/git/repos/$name.git/description
        if [ ! -L /repos/$name.git ]; then
          ln -sf /home/git/repos/$name.git /repos/$name.git
        fi
      }

      install_hooks() {
        local name=$1
        mkdir -p /home/git/repos/$name.git/hooks

        # Pre-receive: enforce merge commits on master
        cp ${hooks}/pre-receive-merge-only /home/git/repos/$name.git/hooks/pre-receive
        chmod +x /home/git/repos/$name.git/hooks/pre-receive

        # Post-receive: mirror to Codeberg
        cp ${hooks}/post-receive-mirror /home/git/repos/$name.git/hooks/post-receive
        chmod +x /home/git/repos/$name.git/hooks/post-receive

        chown -R git:users /home/git/repos/$name.git/hooks
      }

      init_repo "s" "Monorepo."
      init_repo "s-test" "Monorepo testing."

      install_hooks "s"
      install_hooks "s-test"
    '';
  };

  # Fix permissions on every boot/switch
  systemd.services.fix-git-perms = {
    description = "Fix git repository permissions for cgit";
    wantedBy = [ "multi-user.target" ];
    after = [ "init-git-repos.service" ];
    serviceConfig = {
      Type = "oneshot";
    };
    script = ''
      chmod 755 /home/git
      chmod -R o+rX /home/git/repos 2>/dev/null || true
    '';
  };

  system.stateVersion = "24.11";
}
