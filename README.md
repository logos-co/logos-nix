# logos-nix

Shared Nix infrastructure for all Logos projects. Provides a single pinned `nixpkgs` and common build dependencies so downstream repos stay in sync without depending on an actual project as their flake root.

Previously, [`logos-cpp-sdk`](https://github.com/logos-co/logos-cpp-sdk) served as the `follows` root. This caused unnecessary cache invalidation on every SDK commit and coupled infrastructure concerns to an active development project.

## What it provides

| Output | Description |
|---|---|
| `nixpkgs` input | Pinned `nixos-unstable` revision shared across all projects |
| `devShells.default` | Common dev environment: `cmake`, `ninja`, `pkg-config`, `qt6.qtbase`, `qt6.qtremoteobjects` |
| `lib.forAllSystems` | Helper to generate outputs for all supported systems |
| `lib.supportedSystems` | `aarch64-darwin`, `x86_64-darwin`, `aarch64-linux`, `x86_64-linux` |

## Usage

### As a follows root (most projects)

```nix
{
  inputs = {
    logos-nix.url = "github:logos-co/logos-nix";
    nixpkgs.follows = "logos-nix/nixpkgs";
  };
}
```

### Using the dev shell

```nix
{
  inputs = {
    logos-nix.url = "github:logos-co/logos-nix";
    nixpkgs.follows = "logos-nix/nixpkgs";
  };

  outputs = { self, nixpkgs, logos-nix }:
    logos-nix.lib.forAllSystems ({ system, pkgs }: {
      devShells.default = pkgs.mkShell {
        inputsFrom = [ logos-nix.devShells.${system}.default ];
        # add project-specific deps here
      };
    });
}
```

## Migration from logos-cpp-sdk

```diff
 inputs = {
-  logos-cpp-sdk.url = "github:logos-co/logos-cpp-sdk";
-  nixpkgs.follows = "logos-cpp-sdk/nixpkgs";
+  logos-nix.url = "github:logos-co/logos-nix";
+  nixpkgs.follows = "logos-nix/nixpkgs";
+  logos-cpp-sdk.url = "github:logos-co/logos-cpp-sdk";  # only if you need the SDK
 };
```

Then run `nix flake update` to re-lock.

