# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (12);

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    error_log logs/error.log debug;

    lua_shared_dict test_upstream 1m;

    init_by_lua '
        upstream_socket  = require("resty.upstream.socket")

        upstream, configured = upstream_socket:new("test_upstream")

        local pools = {
                primary = {
                    up = true,
                    method = "round_robin",
                    timeout = 100,
                    priority = 0,
                    hosts = {
                        web01 = { host = "127.0.0.1", weight = 10, port = "80", lastfail = 0, failcount = 0, up = true },
                        web02 = { host = "127.0.0.1", weight = 10, port = "80", lastfail = 0, failcount = 0, up = true }
                    }
                },
               tertiary = {
                    up = true,
                    method = "round_robin",
                    timeout = 2000,
                    priority = 15,
                    hosts = {
                        { host = "10.10.10.1", weight = 10, port = "81", lastfail = 0, failcount = 0, up = true }

                    }
                },
                secondary = {
                    up = true,
                    method = "round_robin",
                    timeout = 2000,
                    priority = 10,
                    hosts = {
                        dr01 = { host = "10.10.10.1", weight = 10, port = "80", lastfail = 0, failcount = 0, up = true }

                    }
                }
            }

        upstream:save_pools(pools)
        upstream:sort_pools(pools)

    ';
};

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';

no_long_string();
#no_diff();

run_tests();

__DATA__
=== TEST 1: Dictionary gets set from init_by_lua.
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
             local keys = ngx.shared["test_upstream"]:get_keys()

             if #keys > 0 then
                ngx.status = 200
                ngx.say("OK")
                ngx.exit(200)
            else
                ngx.status = 500
                ngx.say("ERR")
                ngx.exit(500)
            end
        ';
    }
--- request
GET /a
--- response_body
OK
--- no_error_log
[error]
[warn]

=== TEST 2: Dictionary can be unserialised.
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            require "cjson"

            local dict = ngx.shared["test_upstream"]

            local pool_str = dict:get("pools")
            local pools = cjson.decode(pool_str)

            local priority_str = dict:get("priority_index")
            local priority_index = cjson.decode(priority_str)

            local fail = true
            for k,v in pairs(pools) do
                fail = false
            end

            if fail then
                ngx.status = 500; ngx.say("FAIL"); ngx.exit(500)
            end

            local fail = true
            for k,v in pairs(priority_index) do
                fail = false
            end

            if fail then
                ngx.status = 500; ngx.say("FAIL"); ngx.exit(500)
            end
            ngx.say("OK")
        ';
    }
--- request
GET /a
--- response_body
OK
--- no_error_log
[error]
[warn]

=== TEST 3: Pool Priority sorting
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local dict = ngx.shared["test_upstream"]

            local priority_str = dict:get("priority_index")
            local priority_index = cjson.decode(priority_str)

            for k,v in ipairs(priority_index) do
                ngx.say(v)
            end
        ';
    }
--- request
GET /a
--- response_body
primary
secondary
tertiary
--- no_error_log
[error]
[warn]
