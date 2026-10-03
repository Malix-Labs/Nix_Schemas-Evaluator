{ evalLib, ... }:
let
  target = {
    nixosModules.test =
      { lib, ... }:
      {
        options.services.myService = {
          enable = lib.mkEnableOption "test service";
          port = lib.mkOption {
            type = lib.types.port;
            default = 8080;
            description = "Service port";
          };
        };
      };
    darwinModules.test =
      { lib, ... }:
      {
        options.services.myDaemon = {
          enable = lib.mkEnableOption "test daemon";
        };
      };
    homeModules.test =
      { lib, ... }:
      {
        options.programs.myTool = {
          enable = lib.mkEnableOption "test tool";
        };
      };
  };
  eval = evalLib.flake { targetFlake = target; };
in
eval.manifest { options = true; }
