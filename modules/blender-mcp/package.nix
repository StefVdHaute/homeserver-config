# blender-mcp — the official Blender Lab MCP server. Bump with:
#
#   nix-update --flake blender-mcp --version=stable
#
# Also ships the matching Blender add-on as a system extension under
# share/blender/extensions; point BLENDER_SYSTEM_EXTENSIONS there.

{ lib
, python3Packages
, fetchgit
}:

python3Packages.buildPythonApplication rec {
  pname = "blender-mcp";
  version = "1.0.3";
  pyproject = true;

  src = fetchgit {
    url = "https://projects.blender.org/lab/blender_mcp.git";
    tag = "v${version}";
    hash = "sha256-pYeByO4Oi5eyynsJhGVd1vBWXHvhGn+Y5LGit6Kazlw=";
  };

  sourceRoot = "${src.name}/mcp";

  build-system = [ python3Packages.setuptools ];

  dependencies = with python3Packages; [
    docutils
    mcp
    pyyaml
  ];

  postInstall = ''
    mkdir -p $out/share/blender/extensions/system
    cp -r ../addon/blender_mcp_addon $out/share/blender/extensions/system/mcp
  '';

  pythonImportsCheck = [ "blmcp" ];

  meta = {
    description = "Official Blender Lab MCP server for Blender";
    homepage = "https://www.blender.org/lab/mcp-server/";
    license = lib.licenses.gpl3Plus;
    mainProgram = "blender-mcp";
    platforms = lib.platforms.linux;
  };
}
