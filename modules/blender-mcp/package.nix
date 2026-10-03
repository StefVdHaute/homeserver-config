# blender-mcp — the official Blender Lab MCP server. Bump with:
#
#   nix-update --flake blender-mcp --version=stable
#
# The matching Blender add-on comes from the Blender Lab extensions repository
# (https://lab.blender.org/).

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

  pythonImportsCheck = [ "blmcp" ];

  meta = {
    description = "Official Blender Lab MCP server for Blender";
    homepage = "https://www.blender.org/lab/mcp-server/";
    license = lib.licenses.gpl3Plus;
    mainProgram = "blender-mcp";
    platforms = lib.platforms.linux;
  };
}
