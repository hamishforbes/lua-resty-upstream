# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (19);

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    error_log logs/error.log debug;

    lua_shared_dict test_upstream 1m;
};

our $InitConfig = qq{
    init_by_lua '
        cjson = require "cjson"
        upstream_socket  = require("resty.upstream.socket")
        upstream_api = require("resty.upstream.api")

        upstream, configured = upstream_socket:new("test_upstream")
        test_api = upstream_api:new(upstream)

        test_api:create_pool({id = "primary", timeout = 100})

        test_api:create_pool({id = "secondary", timeout = 100, priority = 10})
};

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';

no_long_string();
#no_diff();

run_tests();

__DATA__
=== TEST 1: add_host works
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
        test_api:add_host("primary", { id="a", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1 })
    ';
}
--- log_level: debug
--- config
    location = / {
        content_by_lua '
            local pools, err = upstream:get_pools()
            local idx = upstream.get_host_idx("a", pools.primary.hosts)
            if idx == nil then
                ngx.status = 500
                ngx.say(err)
            end
        ';
    }
--- request
GET /
--- error_code: 200

=== TEST 1b: Cannot add host with existing id
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { id="a", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1 })
            test_api:add_host("primary", { id="a", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1 })
    ';
}
--- log_level: debug
--- config
    location = / {
        content_by_lua '
            local pools, err = upstream:get_pools()
            ngx.say(#pools.primary.hosts)
        ';
    }
--- request
GET /
--- response_body
1

=== TEST 1c: add_host with explicit numeric id is converted to string
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { id=123, host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1 })
    ';
}
--- log_level: debug
--- config
    location = / {
        content_by_lua '
            local pools, err = upstream:get_pools()
            if not type(pools.primary.hosts[1].id) == "string" then
                ngx.status = 500
                ngx.say(err)
            end
        ';
    }
--- request
GET /
--- error_code: 200

=== TEST 1d: add_host with implicit numeric id is converted to string
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", {host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1 })
    ';
}
--- log_level: debug
--- config
    location = / {
        content_by_lua '
            local pools, err = upstream:get_pools()
            if not type(pools.primary.hosts[1].id) == "string" then
                ngx.status = 500
                ngx.say(err)
            end
        ';
    }
--- request
GET /
--- error_code: 200


=== TEST 2: Mixed specific and implied host IDs
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1 })
            test_api:add_host("primary", { id="a", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1 })
            test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1 })
            test_api:add_host("primary", { id="foo", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1 })
    ';
}
--- config
    location = / {
        content_by_lua '
            local pools, err = upstream:get_pools()
            local ids = {}
            for k,v in pairs(pools.primary.hosts) do
                table.insert(ids, tostring(v.id))
            end
            table.sort(ids)
            for k,v in ipairs(ids) do
                ngx.say(v)
            end
        ';
    }
--- request
GET /
--- response_body
1
3
a
foo

=== TEST 3: down_host marks host down
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { id="a", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1 })
    ';
}
--- config
    location = / {
        content_by_lua '
            test_api:down_host("primary", "a")

            local pools, err = upstream:get_pools()
            local idx = upstream.get_host_idx("a", pools.primary.hosts)
            local host = pools.primary.hosts[idx]
            if host.up ~= false then
                ngx.status = 500
            end
        ';
    }
--- request
GET /
--- error_code: 200

=== TEST 3b: down_host with numeric arg marks host down
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1 })
    ';
}
--- config
    location = / {
        content_by_lua '
            test_api:down_host("primary", 1)

            local pools, err = upstream:get_pools()
            local idx = upstream.get_host_idx("1", pools.primary.hosts)
            local host = pools.primary.hosts[idx]
            if host.up ~= false then
                ngx.status = 500
            end
        ';
    }
--- request
GET /
--- error_code: 200


=== TEST 3c: down_host with string arg marks host down
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1 })
    ';
}
--- config
    location = / {
        content_by_lua '
            test_api:down_host("primary", "1")

            local pools, err = upstream:get_pools()
            local idx = upstream.get_host_idx("1", pools.primary.hosts)
            local host = pools.primary.hosts[idx]
            if host.up ~= false then
                ngx.status = 500
            end
        ';
    }
--- request
GET /
--- error_code: 200

=== TEST 4: up_host marks host up
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { id="a", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1 })
    ';
}
--- log_level: debug
--- config
    location = / {
        content_by_lua '
            test_api:down_host("primary", "a")
            test_api:up_host("primary", "a")

            local pools, err = upstream:get_pools()
            local idx = upstream.get_host_idx("a", pools.primary.hosts)
            local host = pools.primary.hosts[idx]
            if host.up ~= true then
                ngx.status = 500
                ngx.say(err)
            end
        ';
    }
--- request
GET /
--- error_code: 200

=== TEST 4b: up_host with numeric arg marks host up
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1 })
    ';
}
--- log_level: debug
--- config
    location = / {
        content_by_lua '
            test_api:down_host("primary", "1")
            test_api:up_host("primary", 1)

            local pools, err = upstream:get_pools()
            local idx = upstream.get_host_idx("1", pools.primary.hosts)
            local host = pools.primary.hosts[idx]
            if host.up ~= true then
                ngx.status = 500
                ngx.say(err)
            end
        ';
    }
--- request
GET /
--- error_code: 200

=== TEST 4b: up_host with string arg marks host up
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1 })
    ';
}
--- log_level: debug
--- config
    location = / {
        content_by_lua '
            test_api:down_host("primary", "1")
            test_api:up_host("primary", "1")

            local pools, err = upstream:get_pools()
            local idx = upstream.get_host_idx("1", pools.primary.hosts)
            local host = pools.primary.hosts[idx]
            if host.up ~= true then
                ngx.status = 500
                ngx.say(err)
            end
        ';
    }
--- request
GET /
--- error_code: 200


=== TEST 5: remove_host deletes host
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { id="a", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1 })
    ';
}
--- log_level: debug
--- config
    location = / {
        content_by_lua '
            test_api:remove_host("primary", "a")

            local pools, err = upstream:get_pools()
            local idx = upstream.get_host_idx("a", pools.primary.hosts)
            if idx ~= nil then
                ngx.status = 500
                ngx.say(err)
            end
        ';
    }
--- request
GET /
--- error_code: 200

=== TEST 5b: remove_host with numeric arg deletes host
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1 })
    ';
}
--- log_level: debug
--- config
    location = / {
        content_by_lua '
            test_api:remove_host("primary", 1)

            local pools, err = upstream:get_pools()
            local idx = upstream.get_host_idx("1", pools.primary.hosts)
            if idx ~= nil then
                ngx.status = 500
                ngx.say(err)
            end
        ';
    }
--- request
GET /
--- error_code: 200

=== TEST 5c: remove_host with string arg deletes host
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1 })
    ';
}
--- log_level: debug
--- config
    location = / {
        content_by_lua '
            test_api:remove_host("primary", "1")

            local pools, err = upstream:get_pools()
            local idx = upstream.get_host_idx("1", pools.primary.hosts)
            if idx ~= nil then
                ngx.status = 500
                ngx.say(err)
            end
        ';
    }
--- request
GET /
--- error_code: 200


=== TEST 6: Cannot set non-numeric weight
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { id="a", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1 })
    ';
}
--- config
    location = /a {
        content_by_lua '
            local ok, err = test_api:set_weight("primary", "a", "foobar")
            if not ok then
                ngx.status = 200
            else
                ngx.status = 500
            end
            ngx.exit(ngx.status)
        ';
    }
--- request
GET /a
--- error_code: 200

=== TEST 7b: Can set numeric weight
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { id="a", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1 })
    ';
}
--- config
    location = /a {
        content_by_lua '
            local ok, err = test_api:set_weight("primary", "a", 5)
            if ok then
                local pools = test_api:get_pools()
                local idx = upstream.get_host_idx("a", pools.primary.hosts)
                local host = pools.primary.hosts[idx]
                if host.weight ~= 5 then
                    ngx.status = 500
                    ngx.log(ngx.ERR, "Weight set to ".. (pools.primary.hosts.a.weight or "nil"))
                else
                    ngx.status = 200
                end
            else
                ngx.say(err)
                ngx.log(ngx.ERR, err)
                ngx.status = 500
            end
            ngx.exit(ngx.status)
        ';
    }
--- request
GET /a
--- error_code: 200

=== TEST 8: Optional host params can be set
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
             local check_params = {
                    path = "/check",
                    headers = {
                        ["User-Agent"] = "Test-Agent"
                    }
                 }
            test_api:add_host("primary", {
                 id="a", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1,
                 healthcheck = check_params
                })
    ';
}
--- log_level: debug
--- config
    location = / {
        content_by_lua '
             local check_params = {
                    path = "/check",
                    headers = {
                        ["User-Agent"] = "Test-Agent"
                    }
                 }

            local pools, err = upstream:get_pools()
            local idx = upstream.get_host_idx("a", pools.primary.hosts)
            local host = pools.primary.hosts[idx]
            local host_check = host.healthcheck

            local r_compare
            r_compare = function (a,b)
                for k,v in pairs(a) do
                    if type(b[k]) == "table" then
                        if not r_compare(b[k], v) then
                            return false
                        end
                    elseif b[k] ~= v then
                        return false
                    end
                end
                return true
            end

            if not r_compare(check_params, host_check) then
                ngx.status = 500
            end
        ';
    }
--- request
GET /
--- error_code: 200

