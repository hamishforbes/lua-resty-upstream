# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (2);

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    error_log logs/error.log debug;

    lua_shared_dict test_upstream 1m;

    init_by_lua '
        cjson = require "cjson"
        upstream_socket  = require("resty.upstream.socket")
        upstream_api = require("resty.upstream.api")

        upstream, configured = upstream_socket:new("test_upstream")
        test_api = upstream_api:new(upstream)

        test_api:create_pool({id = "primary", timeout = 10})

        test_api:create_pool({id = "secondary", timeout = 100, priority = 10})
    ';
};

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';

no_long_string();
#no_diff();

run_tests();

__DATA__
=== TEST 1: Failover to secondary pool
--- http_config eval: $::HttpConfig
--- log_level: debug
--- config
    location = /a {
        content_by_lua '
        -- Bad hosts
            test_api:add_host("primary", { id="a", host = ngx.var.server_addr, port = ngx.var.server_port+1, weight = 10 })
            test_api:add_host("primary", { id="b", host = ngx.var.server_addr, port = ngx.var.server_port+1, weight = 10 })
        -- Good hosts
            test_api:add_host("secondary", { id="a", host = ngx.var.server_addr, port = ngx.var.server_port, weight = 10 })
            test_api:add_host("secondary", { id="b", host = ngx.var.server_addr, port = ngx.var.server_port, weight = 10 })

            local sock, err = upstream:connect()
            if not sock then
                ngx.log(ngx.ERR, err)
                ngx.say(err)
            else
                sock:close()
                ngx.say(err.pool.id)
            end
        ';
    }
--- request
GET /a
--- response_body
secondary
