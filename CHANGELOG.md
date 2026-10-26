# Changelog

## [1.2.0](https://github.com/mtxr/claude-switch/compare/v1.1.0...v1.2.0) (2026-10-26)


### Features

* **nix:** make csw the prebuilt release binary ([#51](https://github.com/mtxr/claude-switch/issues/51)) ([eb4988c](https://github.com/mtxr/claude-switch/commit/eb4988ced4945a613330f433ad8d2e5008b3dcbe))

## [1.1.0](https://github.com/mtxr/claude-switch/compare/v1.0.1...v1.1.0) (2026-10-26)


### Features

* open a profile's own Claude Desktop next to the main one with csw desktop ([#49](https://github.com/mtxr/claude-switch/issues/49)) ([061dbe7](https://github.com/mtxr/claude-switch/commit/061dbe79a5037850f0c54024595d50e8c0563fdc))

## [1.0.1](https://github.com/mtxr/claude-switch/compare/v1.0.0...v1.0.1) (2026-10-26)


### Bug Fixes

* close three known limitations (Keychain argv, Desktop force-quit, inner config link) ([#44](https://github.com/mtxr/claude-switch/issues/44)) ([bce9fb9](https://github.com/mtxr/claude-switch/commit/bce9fb9901075628719ab97a309695f8baa6bb57))

## [1.0.0](https://github.com/mtxr/claude-switch/compare/v0.2.6...v1.0.0) (2026-10-24)


### ⚠ BREAKING CHANGES

* use, new, delete and logout-all no longer quit, swap or remove Claude Desktop data by default. Migration: add --all to keep the previous behaviour of switching Code and Desktop together.

### Features

* add a built-in profile picker so sk and fzf are optional ([#36](https://github.com/mtxr/claude-switch/issues/36)) ([a1e8a45](https://github.com/mtxr/claude-switch/commit/a1e8a457d3a7fe817366633ccb5ed99d72a3e660))
* add csw bind and a zsh/bash shell hook for per-directory profiles ([#26](https://github.com/mtxr/claude-switch/issues/26)) ([da3d4d7](https://github.com/mtxr/claude-switch/commit/da3d4d7727217bebb1746884ca82dbcbde61dc29))
* add csw rename to rename a profile with its login and Desktop data ([#29](https://github.com/mtxr/claude-switch/issues/29)) ([8e809b2](https://github.com/mtxr/claude-switch/commit/8e809b24901ea7e02fba65aac689749b13db37b8))
* add fish completions and hook, and a generated man page ([#34](https://github.com/mtxr/claude-switch/issues/34)) ([b8627fe](https://github.com/mtxr/claude-switch/commit/b8627fe3d594ec0098228db4b325a02227568e12))
* add run, login and env commands for concurrent profiles ([#21](https://github.com/mtxr/claude-switch/issues/21)) ([4237237](https://github.com/mtxr/claude-switch/commit/4237237fde0de0138a3d593d51dabb756e136519))
* add the edge channel to csw update and install.sh ([#40](https://github.com/mtxr/claude-switch/issues/40)) ([04bc3f5](https://github.com/mtxr/claude-switch/commit/04bc3f58b5f7f57c2aae48c75da3184c311076de))
* decouple Claude Desktop from Claude Code with --desktop and --all ([#24](https://github.com/mtxr/claude-switch/issues/24)) ([c0e150a](https://github.com/mtxr/claude-switch/commit/c0e150a36a76eb0eb81ba1fd41025b770f7b11c3))
* generate zsh and bash completions from a command table ([#28](https://github.com/mtxr/claude-switch/issues/28)) ([32a7dc9](https://github.com/mtxr/claude-switch/commit/32a7dc97678c882f9ccaab56a77e1ab839d2b85b))
* Linux support, unit tests and CI matrix ([#20](https://github.com/mtxr/claude-switch/issues/20)) ([4f8b2ca](https://github.com/mtxr/claude-switch/commit/4f8b2caeca8966533b2407127bc68b7bcbc89221))
* open the picker when a command is run without a profile name ([#27](https://github.com/mtxr/claude-switch/issues/27)) ([577b642](https://github.com/mtxr/claude-switch/commit/577b642568784d7f606d555e67666c02b568e4da))
* show account email next to profile name in picker ([#16](https://github.com/mtxr/claude-switch/issues/16)) ([11322aa](https://github.com/mtxr/claude-switch/commit/11322aa047bde8c7fdd2ccb0585918a80d12dccb))
* store Claude Code logins in the per-directory Keychain entry ([#23](https://github.com/mtxr/claude-switch/issues/23)) ([685571c](https://github.com/mtxr/claude-switch/commit/685571cfb6eae6408569c6fafd660da7fa4001c2))
* verify csw update downloads and defer to package managers ([#35](https://github.com/mtxr/claude-switch/issues/35)) ([ee2b967](https://github.com/mtxr/claude-switch/commit/ee2b9674f45ac378649c59e6d669e96f2ff0b79e))
* warn about a dangling .csw and extend csw doctor ([#30](https://github.com/mtxr/claude-switch/issues/30)) ([e9c021c](https://github.com/mtxr/claude-switch/commit/e9c021cef26e4e30c603045e923935d6a718e37b))


### Bug Fixes

* explain that update --edge needs a standalone install ([#42](https://github.com/mtxr/claude-switch/issues/42)) ([2a3a6cd](https://github.com/mtxr/claude-switch/commit/2a3a6cda18d0ec95a9e3fda7852c453f122a941e))
* hide desktop session token in whoami ([#14](https://github.com/mtxr/claude-switch/issues/14)) ([f44a8c0](https://github.com/mtxr/claude-switch/commit/f44a8c017063269162cc3eed4b6db68a14d02a4f))
* stop dropping output larger than 4096 bytes ([#33](https://github.com/mtxr/claude-switch/issues/33)) ([251d0a8](https://github.com/mtxr/claude-switch/commit/251d0a8c22ccaffc6a5f6ace8cad870fa0c72d69))

## [0.2.6](https://github.com/mtxr/claude-switch/compare/v0.2.5...v0.2.6) (2026-06-11)


### Bug Fixes

* bump VERSION to 0.2.5 and wire release-please to src/main.zig ([#12](https://github.com/mtxr/claude-switch/issues/12)) ([cd4210e](https://github.com/mtxr/claude-switch/commit/cd4210e4ed6d786dd9df11867c590ad8d08cb192))

## [0.2.5](https://github.com/mtxr/claude-switch/compare/v0.2.4...v0.2.5) (2026-06-11)


### Bug Fixes

* correct release asset name and add --verbose flag to update ([#10](https://github.com/mtxr/claude-switch/issues/10)) ([19091a6](https://github.com/mtxr/claude-switch/commit/19091a6af3c34b8f89787806fc48a03d717891e9))

## [0.2.4](https://github.com/mtxr/claude-switch/compare/v0.2.3...v0.2.4) (2026-06-11)


### Bug Fixes

* build arch-specific binaries in release workflow ([#8](https://github.com/mtxr/claude-switch/issues/8)) ([d81d617](https://github.com/mtxr/claude-switch/commit/d81d6172893d26198badcba8b1c9e6ce4b380220))

## [0.2.3](https://github.com/mtxr/claude-switch/compare/v0.2.2...v0.2.3) (2026-06-10)


### Bug Fixes

* use native runners per arch to fix sqlite3 cross-compilation ([#6](https://github.com/mtxr/claude-switch/issues/6)) ([e63cb60](https://github.com/mtxr/claude-switch/commit/e63cb60e6b3df52127b9a9b61df758198ae9a004))

## [0.2.2](https://github.com/mtxr/claude-switch/compare/v0.2.1...v0.2.2) (2026-06-10)


### Bug Fixes

* correct release-please tag format and build trigger ([#4](https://github.com/mtxr/claude-switch/issues/4)) ([51509d2](https://github.com/mtxr/claude-switch/commit/51509d218c6e785322e9c72fce3516570cc342bd))
* use-after-free in profile switch + doctor command + background update check ([#1](https://github.com/mtxr/claude-switch/issues/1)) ([1cf109e](https://github.com/mtxr/claude-switch/commit/1cf109e89d6654c4a596e01110750fbd44868282))

## [0.2.1](https://github.com/mtxr/claude-switch/compare/csw-v0.2.0...csw-v0.2.1) (2026-06-10)


### Bug Fixes

* use-after-free in profile switch + doctor command + background update check ([#1](https://github.com/mtxr/claude-switch/issues/1)) ([1cf109e](https://github.com/mtxr/claude-switch/commit/1cf109e89d6654c4a596e01110750fbd44868282))
