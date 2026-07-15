{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.lightpanda;

  /**
    Convert a camelCase or snake_case key to --kebab-case CLI flag,
    then append the value.

    -  `true`   -> flag with no value  (e.g. --block-private-networks)
    -  `false`  -> omitted
    -  string or int  -> flag value     (e.g. --port 9222)
    -  list of strings -> flag with comma-separated values (e.g. --block-cidrs 10.0.0.0/8,172.16.0.0/12)
  */
  camelToKebab =
    s:
    let
      len = builtins.stringLength s;
      go =
        i:
        if i >= len then
          ""
        else
          let
            c = builtins.substring i 1 s;
            isUpper = c != toLower c && c == toUpper c;
            prefix = if i > 0 && isUpper then "-" else "";
          in
          prefix + toLower c + go (i + 1);
    in
    go 0;

  flagsFromSettings =
    settings:
    let
      processOne =
        name: value:
        let
          flag = "--${camelToKebab name}";
        in
        if isBool value then
          optional value flag
        else if isList value then
          [
            flag
            (concatMapStringsSep "," (x: toString x) value)
          ]
        else if isString value || isInt value then
          [
            flag
            (toString value)
          ]
        else
          [ ];
    in
    concatLists (mapAttrsToList processOne settings);

  # The last part of the package path so we can reference the store path.
  lightpandaPkg = cfg.package;

in
{

  options.services.lightpanda = {

    enable = mkEnableOption "Lightpanda headless browser CDP server";

    package = mkPackageOption pkgs "lightpanda" { };

    settings = mkOption {
      type = types.attrsOf (
        types.oneOf [
          types.bool
          types.int
          types.str
          (types.listOf types.str)
        ]
      );
      default = { };
      description = ''
        Settings passed as CLI flags to `lightpanda serve`.

        Keys are converted from camelCase or snake_case to kebab-case
        (e.g. `blockPrivateNetworks` → `--block-private-networks`).

        -  `true` renders as a bare flag  (e.g. `--obey-robots`)
        -  `false` or absent values are omitted
        -  strings and ints render as `--key value`
        -  lists of strings render as `--key v1,v2,…`
      '';
      example = {
        host = "127.0.0.1";
        port = 9222;
        logLevel = "info";
        blockPrivateNetworks = true;
        storageEngine = "sqlite";
        storageSqlitePath = "/var/lib/lightpanda/state.db";
      };
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Extra CLI arguments appended verbatim to `lightpanda serve`.";
      example = [
        "--v8-flags-unsafe"
        "--expose-gc"
      ];
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open the CDP server TCP port in the firewall.";
    };
  };

  config = mkIf cfg.enable {

    # The package must be available.  If using the flake, the
    # `nixosModules.default` already injects it via overlay.
    environment.systemPackages = [ lightpandaPkg ];

    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [ (cfg.settings.port or 9222) ];
    };

    systemd.services.lightpanda = {
      description = "Lightpanda headless browser CDP server";
      documentation = [ "https://lightpanda.io" ];
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";

        ExecStart = ''
          ${getExe lightpandaPkg} serve ${escapeShellArgs (flagsFromSettings cfg.settings ++ cfg.extraArgs)}
        '';

        # ---------- Dynamic user / state ----------
        DynamicUser = true;
        StateDirectory = "lightpanda";
        RuntimeDirectory = "lightpanda";

        # ---------- Filesystem sandboxing ----------
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;

        # ---------- Capabilities / privileges ----------
        NoNewPrivileges = true;
        CapabilityBoundingSet = [ "" ];
        LockPersonality = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];

        # ---------- System call filtering ----------
        SystemCallArchitectures = "native";

        # ---------- Restart policy ----------
        Restart = "always";
        RestartSec = 5;

        # ---------- Hardening ----------
        UMask = "0077";
      };
    };
  };
}
