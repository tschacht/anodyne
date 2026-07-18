rockspec_format = "3.0"
package = "anodyne-test-tools"
version = "dev-0"
source = {
  url = "git+file://.",
}
description = {
  summary = "Non-publishable test dependencies for Anodyne",
  license = "UNLICENSED",
}
dependencies = {
  "lua >= 5.4, < 5.5",
  "busted == 2.3.0",
  "luacov == 0.17.0",
}
build = {
  type = "builtin",
  modules = {},
}
