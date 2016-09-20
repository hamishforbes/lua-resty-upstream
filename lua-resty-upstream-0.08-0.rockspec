package = "lua-resty-upstream"
version = "0.08-0"
source = {
  url = "git://github.com/hamishforbes/lua-resty-upstream",
  tag = "v0.08"
}
description = {
  summary = "Upstream connection load balancing and failover module for Openresty",
  homepage = "https://github.com/hamishforbes/lua-resty-upstream",
  license = "MIT",
  maintainer = "Hamish Forbes"
}
dependencies = {
    "lua >= 5.1",
    "lua-resty-http >= 0.09",
}
build = {
  type = "builtin",
  modules = {
    ["resty.upstream.socket"] = "lib/resty/upstream/socket.lua",
    ["resty.upstream.http"] = "lib/resty/upstream/http.lua",
    ["resty.upstream.api"] = "lib/resty/upstream/api.lua",
  }
}
