SHELL := /bin/sh
LUA := $(CURDIR)/.lua/bin/lua
LUAROCKS := $(CURDIR)/.lua/bin/luarocks
BUSTED := $(CURDIR)/.lua/bin/busted
LUACOV := $(CURDIR)/.lua/bin/luacov
STYLUA := $(CURDIR)/.tools/stylua
TIMEOUT := $(CURDIR)/tools/run_with_timeout.py
MILESTONE ?= 2
LOCAL_CONFIG := $(CURDIR)/.lua/etc/luarocks/config-5.4.lua
LOCAL_HOME := $(CURDIR)/.lua/home
LOCAL_ENV := HOME=$(LOCAL_HOME) LUAROCKS_CONFIG=$(LOCAL_CONFIG) LUA_PATH=';;' LUA_CPATH=';;'

.PHONY: bootstrap toolchain-check test test-characterization coverage format-check verify deps-update

bootstrap:
	@tools/bootstrap

toolchain-check:
	@python3 tools/environment_manifest.py validate "$(CURDIR)" "$(CURDIR)/.lua/anodyne-environment.manifest"
	@test -x "$(LUA)" -a -x "$(LUAROCKS)" -a -x "$(BUSTED)" -a -x "$(LUACOV)" -a -x "$(STYLUA)"
	@test -f "$(LOCAL_CONFIG)"
	@$(LUA) -v 2>&1 | grep -Eq '^Lua 5\.4\.7([^0-9]|$$)'
	@$(LOCAL_ENV) $(LUAROCKS) --version | grep -Eq '3\.13\.0([^0-9]|$$)'
	@$(LOCAL_ENV) $(BUSTED) --version | grep -Eq '2\.3\.0([^0-9]|$$)'
	@$(LOCAL_ENV) $(LUA) -e 'io.write(assert(require("luacov.runner").version), "\n")' | grep -Eq '^0\.17\.0$$'
	@$(STYLUA) --version | grep -Eq '2\.5\.2([^0-9]|$$)'
	@$(LOCAL_ENV) $(LUAROCKS) config lua_version | grep -qx '5.4'
	@$(LOCAL_ENV) $(LUAROCKS) config rocks_trees | grep -Fq '$(CURDIR)/.lua'
	@! $(LOCAL_ENV) $(LUAROCKS) config rocks_trees | grep -E '/usr/local|/opt/homebrew|/Users/.*/\.luarocks'
	@$(LOCAL_ENV) $(LUAROCKS) list --porcelain | $(LOCAL_ENV) $(LUA) tools/check_lock.lua luarocks.lock
	@python3 tools/build_local_rock_repo.py check tools/luarocks-artifacts.env .tools/cache/luarocks-artifacts .tools/luarocks-repo

test: toolchain-check
	@. tools/test-minimums.env; $(LOCAL_ENV) $(TIMEOUT) --seconds 90 --minimum-examples "$$TEST_MINIMUM_FULL" -- $(BUSTED) --config-file=.busted

test-characterization: toolchain-check
	@. tools/test-minimums.env; $(LOCAL_ENV) $(TIMEOUT) --seconds 30 --minimum-examples "$$TEST_MINIMUM_CHARACTERIZATION" -- $(BUSTED) --config-file=.busted spec/characterization

coverage: toolchain-check
	@mkdir -p coverage
	@. tools/test-minimums.env; $(LOCAL_ENV) $(TIMEOUT) --seconds 90 --minimum-examples "$$TEST_MINIMUM_FULL" -- $(BUSTED) --config-file=.busted --coverage
	@$(LOCAL_ENV) $(LUACOV) -c .luacov
	@$(LOCAL_ENV) $(LUA) tools/check_coverage.lua --milestone $(MILESTONE)
	@rm -f coverage/luacov.stats.out

format-check: toolchain-check
	@$(STYLUA) --check init.lua spec tools/check_coverage.lua tools/check_lock.lua tools/normalize_lock.lua

verify: format-check test coverage

deps-update:
	@printf '%s\n' 'dependency updates require a separate authorized network task' >&2
	@exit 2
