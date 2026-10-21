{ dotfiles, ... }:

# The Home Manager modules from the dotfiles repo, which the Arch install
# applies standalone. DOTFILES.md has which configs they cover and the order
# for moving more of them off Stow.
{
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;

    # A file Home Manager would replace gets this suffix instead of failing
    # the switch: covers a Stow link left behind on this host.
    backupFileExtension = "pre-hm";

    users.stef = {
      imports = [ dotfiles.homeModules.default ];
      home.stateVersion = "26.05";
    };
  };
}
