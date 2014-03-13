# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (29);

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

        test_api:create_pool({id = "primary", timeout = 100})

        test_api:create_pool({id = "secondary", timeout = 100, priority = 10})
    ';
};

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';

no_long_string();
#no_diff();

run_tests();

__DATA__
=== TEST 1: api:get_pools passes through to upstream
--- http_config eval: $::HttpConfig
--- log_level: debug
--- config
    location = / {
        content_by_lua '
            test_api:add_host("primary", { id="a", host = ngx.var.server_addr, port = ngx.var.server_port, weight = 1 })

            local pools, err = test_api:get_pools()
            local idx = upstream.get_host_idx("a", pools.primary.hosts)
            local host = pools.primary.hosts[idx]
            if host == nil then
                ngx.status = 500
                ngx.say(err)
            end
        ';
    }
--- request
GET /
--- error_code: 200

=== TEST 2: create_pool works
--- http_config eval: $::HttpConfig
--- log_level: debug
--- config
    location = /a {
        content_by_lua '
            local ok,err = test_api:create_pool({id = "test"})

            local pools, err = upstream:get_pools()
            if pools["test"] == nil then
                ngx.status = 500
                ngx.say(err)
            end
            ngx.exit(ngx.status)
        ';
    }
--- request
GET /a
--- errorcode: 200

=== TEST 2b: create_pool with a numeric id creates a string id
--- http_config eval: $::HttpConfig
--- log_level: debug
--- config
    location = /a {
        content_by_lua '
            local ok, err = test_api:create_pool({id = 1234})

            local pools, err = upstream:get_pools()
            if pools["1234"] == nil or pools[1234] ~= nil then
                ngx.status = 500
                ngx.say(err)
            end
            ngx.exit(ngx.status)
        ';
    }
--- request
GET /a
--- errorcode: 200

=== TEST 3: Cannot add existing pool
--- http_config eval: $::HttpConfig
--- log_level: debug
--- config
    location = /a {
        content_by_lua '
            local ok,err = test_api:create_pool({id = "primary"})
            if not ok then
                ngx.say("OK")
                ngx.status = 200
            else
                ngx.say(err)
                ngx.status = 500
            end
            ngx.exit(ngx.status)
        ';
    }
--- request
GET /a
--- errorcode: 200
--- response_body
OK

=== TEST 3: Cannot set unavailable load-balancing method
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local ok, err = test_api:set_method("primary", "foobar")
            if not ok then
                ngx.say("OK")
                ngx.status = 200
            else
                ngx.say(err)
                ngx.status = 500
            end
            ngx.exit(ngx.status)
        ';
    }
--- request
GET /a
--- error_code: 200
--- response_body
OK

=== TEST 3b: Can set available load-balancing method
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local ok, err = test_api:set_method("primary", "round_robin")
            if ok then
                ngx.say("OK")
                ngx.status = 200
            else
                ngx.say(err)
                ngx.status = 500
            end
            ngx.exit(ngx.status)
        ';
    }
--- request
GET /a
--- error_code: 200
--- response_body
OK

=== TEST 3c: Can set available load-balancing method on numeric id with string arg
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local ok, err = test_api:create_pool({id = 1234})
            local ok, err = test_api:set_method("1234", "round_robin")
            if ok then
                ngx.say("OK")
                ngx.status = 200
            else
                ngx.say(err)
                ngx.status = 500
            end
            ngx.exit(ngx.status)
        ';
    }
--- request
GET /a
--- error_code: 200
--- response_body
OK

=== TEST 3c: Can set available load-balancing method on numeric id with numeric arg
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local ok, err = test_api:create_pool({id = 1234})
            local ok, err = test_api:set_method(1234, "round_robin")
            if ok then
                ngx.say("OK")
                ngx.status = 200
            else
                ngx.say(err)
                ngx.status = 500
            end
            ngx.exit(ngx.status)
        ';
    }
--- request
GET /a
--- error_code: 200
--- response_body
OK


=== TEST 4: Cannot set non-numeric priority
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local ok, err = test_api:set_priority("primary", "foobar")
            if not ok then
                ngx.say("OK")
                ngx.status = 200
            else
                ngx.say(err)
                ngx.status = 500
            end
            ngx.exit(ngx.status)
        ';
    }
--- request
GET /a
--- error_code: 200
--- response_body
OK

=== TEST 4b: Can set numeric priority
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local ok, err = test_api:set_priority("primary", 5)
            if ok then
                local pools = test_api:get_pools()
                if pools.primary.priority ~= 5 then
                    ngx.say(pools.primary.priority)
                    ngx.status = 500
                else
                    ngx.say("OK")
                    ngx.status = 200
                end
            else
                ngx.say(err)
                ngx.status = 500
            end
            ngx.exit(ngx.status)
        ';
    }
--- request
GET /a
--- error_code: 200
--- response_body
OK

=== TEST 4c: Can set priority on numeric pool with string arg
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local ok, err = test_api:create_pool({id = 1234})
            local ok, err = test_api:set_priority("1234", 5)
            if ok then
                local pools = test_api:get_pools()
                if pools["1234"].priority ~= 5 then
                    ngx.status = 500
                else
                    ngx.say("OK")
                    ngx.status = 200
                end
            else
                ngx.say(err)
                ngx.status = 500
            end
            ngx.exit(ngx.status)
        ';
    }
--- request
GET /a
--- error_code: 200
--- response_body
OK

=== TEST 4d: Can set priority on numeric pool with numeric arg
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local ok, err = test_api:create_pool({id = 1234})
            local ok, err = test_api:set_priority(1234, 5)
            if ok then
                local pools = test_api:get_pools()
                if pools["1234"].priority ~= 5 then
                    ngx.status = 500
                else
                    ngx.say("OK")
                    ngx.status = 200
                end
            else
                ngx.say(err)
                ngx.status = 500
            end
            ngx.exit(ngx.status)
        ';
    }
--- request
GET /a
--- error_code: 200
--- response_body
OK


=== TEST 5: Cannot create pool with bad values
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local ok, err = test_api:create_pool({
                    id = "testpool",
                    priority = "abcd",
                    timeout = "foo",
                    method = "bar",
                    max_fails = "three",
                    fail_timeout = "sixty"
                })

            if not ok then
                ngx.say("OK")
                ngx.status = 200
            else
                ngx.say(err)
                ngx.status = 500
            end
            ngx.exit(ngx.status)
        ';
    }
--- request
GET /a
--- error_code: 200
--- response_body
OK

=== TEST 6: Cannot add host to non-existent pool
--- http_config eval: $::HttpConfig
--- config
    location = / {
        content_by_lua '
            local ok, err = test_api:add_host("foobar", { id="a", host = ngx.var.server_addr, port = ngx.var.server_port+1, weight = 10 })
            if not ok then
                ngx.say("OK")
                ngx.status = 200
            else
                ngx.say(err)
                ngx.status = 500
            end
            ngx.exit(ngx.status)
        ';
    }
--- request
GET /
--- errorcode: 200
--- response_body
OK

=== TEST 6b: Can add host to numeric pool with string arg
--- http_config eval: $::HttpConfig
--- config
    location = / {
        content_by_lua '
            local ok, err = test_api:create_pool({id = 1234})
            local ok, err = test_api:add_host("1234", { id="a", host = ngx.var.server_addr, port = ngx.var.server_port+1, weight = 10 })

            local pools, err = upstream:get_pools()
            if #pools["1234"].hosts == 0 then
                ngx.status = 500
                ngx.say(err)
            else
                ngx.say("OK")
            end

            ngx.exit(ngx.status)
        ';
    }
--- request
GET /
--- errorcode: 200
--- response_body
OK

=== TEST 6c: Can add host to numeric pool with numeric arg
--- http_config eval: $::HttpConfig
--- config
    location = / {
        content_by_lua '
            local ok, err = test_api:create_pool({id = 1234})
            local ok, err = test_api:add_host(1234, { id="a", host = ngx.var.server_addr, port = ngx.var.server_port+1, weight = 10 })

            local pools, err = upstream:get_pools()
            if #pools["1234"].hosts == 0 then
                --ngx.status = 500
                ngx.say(err)
            else
                ngx.say("OK")
            end

            ngx.exit(ngx.status)
        ';
    }
--- request
GET /
--- errorcode: 200
--- response_body
OK
