{ config, pkgs, lib, modulesPath, ... }:

let
  hooks = ./hooks;

  # authentik forward auth configuration (shared between vhosts)
  authentikOutpost = "https://sso.sdko.net/outpost.goauthentik.io";

  forwardAuthConfig = ''
    auth_request        /outpost.goauthentik.io/auth/nginx;
    error_page          401 = @goauthentik_proxy_signin;
    auth_request_set    $auth_cookie $upstream_http_set_cookie;
    add_header          Set-Cookie $auth_cookie;

    # Translate headers from the outpost back to the upstream
    auth_request_set $authentik_username $upstream_http_x_authentik_username;
    auth_request_set $authentik_groups $upstream_http_x_authentik_groups;
    auth_request_set $authentik_entitlements $upstream_http_x_authentik_entitlements;
    auth_request_set $authentik_email $upstream_http_x_authentik_email;
    auth_request_set $authentik_name $upstream_http_x_authentik_name;
    auth_request_set $authentik_uid $upstream_http_x_authentik_uid;

    proxy_set_header X-authentik-username $authentik_username;
    proxy_set_header X-authentik-groups $authentik_groups;
    proxy_set_header X-authentik-entitlements $authentik_entitlements;
    proxy_set_header X-authentik-email $authentik_email;
    proxy_set_header X-authentik-name $authentik_name;
    proxy_set_header X-authentik-uid $authentik_uid;
  '';

  # Shared authentik locations for each vhost
  authentikLocations = {
    # All requests to /outpost.goauthentik.io must be accessible without authentication
    "/outpost.goauthentik.io" = {
      proxyPass = authentikOutpost;
      extraConfig = ''
        proxy_ssl_verify              off;
        proxy_set_header              Host sso.sdko.net;
        proxy_set_header              X-Forwarded-Host $host;
        proxy_set_header              X-Original-URL $scheme://$http_host$request_uri;
        add_header                    Set-Cookie $auth_cookie;
        auth_request_set              $auth_cookie $upstream_http_set_cookie;
        proxy_pass_request_body       off;
        proxy_set_header              Content-Length "";
      '';
    };

    # When the /auth endpoint returns 401, redirect to /start to initiate SSO
    "@goauthentik_proxy_signin" = {
      extraConfig = ''
        internal;
        add_header Set-Cookie $auth_cookie;
        return 302 /outpost.goauthentik.io/start?rd=$scheme://$http_host$request_uri;
      '';
    };
  };

  # Common SSL config
  sslConfig = {
    forceSSL = true;
    sslCertificate = "/etc/ssl/git.sdko.net/fullchain.cer";
    sslCertificateKey = "/etc/ssl/git.sdko.net/key.pem";
    extraConfig = ''
      proxy_buffers 8 16k;
      proxy_buffer_size 32k;
    '';
  };
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
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH7guBCBEx3TZ+2S6m+aKBg9ABSS+0nRvPcu7GjTOwVf"
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

  # Prometheus node exporter
  services.prometheus.exporters.node = {
    enable = true;
    port = 9100;
    listenAddress = "127.0.0.1";
    enabledCollectors = [
      "systemd"
      "processes"
    ];
  };

  # cgit configuration
  services.cgit.main = {
    enable = true;
    nginx.virtualHost = "git.sdko.net";
    scanPath = "/repos";
    settings = {
      root-title = "Git Repositories";
      root-desc = "Public git repositories";
      enable-index-owner = 0;
      enable-commit-graph = 1;
      enable-log-filecount = 1;
      enable-log-linecount = 1;
      max-repo-count = 50;
      cache-size = 1000;
      snapshots = "tar.gz tar.xz zip";
      clone-url = "https://git.sdko.net/$CGIT_REPO_URL git@git.sdko.net:repos/$CGIT_REPO_URL";
      source-filter = "${pkgs.cgit}/lib/cgit/filters/syntax-highlighting.py";
      about-filter = "${pkgs.cgit}/lib/cgit/filters/about-formatting.sh";
    };
  };

  # nginx
  services.nginx = {
    enable = true;
    recommendedOptimisation = true;
    recommendedGzipSettings = true;
    recommendedProxySettings = false;
    serverTokens = false;
    package = pkgs.nginxMainline.override {
      modules = [ pkgs.nginxModules.moreheaders ];
    };

    commonHttpConfig = ''
      more_set_headers "Server: SDKO Git Server";
      more_set_headers "Via: 1.1 sws-gateway";

      map $http_upgrade $connection_upgrade_keepalive {
        default upgrade;
        ""      "";
      }
    '';

    virtualHosts."git.sdko.net" = sslConfig // {
      locations = authentikLocations // {
        "/" = {
          extraConfig = forwardAuthConfig + ''
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            # WebSocket support
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade_keepalive;
          '';
        };
      };
    };

    virtualHosts."nodeexporter-git-svc.sdko.net" = sslConfig // {
      locations = authentikLocations // {
        "/" = {
          proxyPass = "http://127.0.0.1:9100";
          extraConfig = forwardAuthConfig + ''
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
          '';
        };
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
        local skip_prereceive=$2
        mkdir -p /home/git/repos/$name.git/hooks

        # Pre-receive: enforce merge commits on master
        if [ "$skip_prereceive" != "true" ]; then
          cp ${hooks}/pre-receive-merge-only /home/git/repos/$name.git/hooks/pre-receive
          chmod +x /home/git/repos/$name.git/hooks/pre-receive
        else
          rm -f /home/git/repos/$name.git/hooks/pre-receive
        fi

        # Post-receive: mirror to Codeberg
        cp ${hooks}/post-receive-mirror /home/git/repos/$name.git/hooks/post-receive
        chmod +x /home/git/repos/$name.git/hooks/post-receive

        chown -R git:users /home/git/repos/$name.git/hooks
      }

      init_repo "s" "Monorepo."
      init_repo "s-test" "Monorepo testing."
      init_repo "hl-bootstrap-automatic" "Homelab bootstrap (auto-synced from monorepo)."
      init_repo "m" "Mom's project."

      install_hooks "s"
      install_hooks "s-test"
      install_hooks "hl-bootstrap-automatic" true
      install_hooks "m"
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
