# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * 11;

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
        upstream_http  = require("resty.upstream.http")
        upstream_api = require("resty.upstream.api")

        upstream, configured = upstream_socket:new("test_upstream")
        test_api = upstream_api:new(upstream)
        http = upstream_http:new(upstream)

        test_api:create_pool({id = "primary", timeout = 100, read_timeout = 1100, keepalive_timeout = 1, status_codes = {["5xx"] = true} })

        test_api:create_pool({id = "secondary", timeout = 100, priority = 10, status_codes = {["5xx"] = true}})
};

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';

no_long_string();
#no_diff();

run_tests();

__DATA__
=== TEST 1: HTTP Requests pass through
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { id="a", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 10 })
    ';
}
--- log_level: debug
--- config
    location = /a {
        content_by_lua '
            local res, err, status = http:request({
                method = "GET",
                path = "/test",
                headers = ngx.req.get_headers(),
            })

            if not res then
                ngx.status = status
                ngx.say(err)
                return ngx.exit(ngx.status)
            end

            local body = res:read_body()
            ngx.print(body)

        ';
    }
    location = /test {
        echo 'response';
    }
--- request
GET /a
--- response_body
response

=== TEST 2: HTTP Status causes failover
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { id="a", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 10 })
            test_api:add_host("secondary", { id="b", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 10 })
    ';
}
--- log_level: debug
--- config
    location = /a {
        content_by_lua '
            local res, err, status = http:request({
                method = "GET",
                path = "/test",
                headers = ngx.req.get_headers(),
            })

            if not res then
                ngx.status = status
                ngx.say(err)
                return ngx.exit(ngx.status)
            end

            local body = res:read_body()
            ngx.print(body)
            local host, pool = err.host, err.pool
            ngx.say(host.id)
            ngx.say(pool.id)

        ';
    }
    location = /test {
        content_by_lua '
            local first = ngx.shared.test_upstream:get("first_flag")

            if not first then
                ngx.shared.test_upstream:set("first_flag", true)
                ngx.status = 500
                ngx.say("error")
                return ngx.exit(500)
            end

            ngx.say("response")
        ';
    }
--- request
GET /a
--- response_body
response
b
secondary

=== TEST 3: No connections returns 504
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { id="a", host = "127.0.0.1", port = 8$TEST_NGINX_SERVER_PORT, weight = 10 })
            test_api:add_host("secondary", { id="b", host = "127.0.0.1", port = 8$TEST_NGINX_SERVER_PORT, weight = 10 })
    ';
}
--- log_level: debug
--- config
    location = /a {
        content_by_lua '
            local res, err, status = http:request({
                method = "GET",
                path = "/test",
                headers = ngx.req.get_headers(),
            })

            if not res then
                ngx.status = status
                ngx.say(err)
                return ngx.exit(ngx.status)
            end

            local body = res:read_body()
            ngx.print(body)

        ';
    }

--- request
GET /a
--- error_code: 504

=== TEST 4: Connection but bad HTTP response returns 502
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { id="a", host = "127.0.0.1", port = 8$TEST_NGINX_SERVER_PORT, weight = 10 })
            test_api:add_host("secondary", { id="b", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 10 })
    ';
}
--- log_level: debug
--- config
    location = /a {
        content_by_lua '
            local res, err, status = http:request({
                method = "GET",
                path = "/test",
                headers = ngx.req.get_headers(),
            })

            if not res then
                ngx.status = status
                ngx.say(err)
                return ngx.exit(ngx.status)
            end

            local body = res:read_body()
            ngx.print(body)

        ';
    }
    location = /test {
        content_by_lua '
            ngx.status = 500
            ngx.say("error")
            return ngx.exit(500)
        ';
    }

--- request
GET /a
--- error_code: 502

=== TEST 5: Read timeout can be set
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { id="a", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 10 })
    ';
}
--- log_level: debug
--- config
    location = /a {
        content_by_lua '
            local res, err, status = http:request({
                method = "GET",
                path = "/test",
                headers = ngx.req.get_headers(),
            })

            if not res then
                ngx.status = status
                ngx.say(err)
                return ngx.exit(ngx.status)
            end

            local body = res:read_body()
            ngx.print(body)

        ';
    }
    location = /test {
        content_by_lua '
            ngx.sleep(1)
            ngx.say("slow!")
        ';
    }

--- request
GET /a
--- error_code: 200

=== TEST 6: Pool keepalive overrides set_keepalive call
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { id="a", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 10 })
    ';
}
--- log_level: debug
--- config
    location = /a {
        content_by_lua '
           local res, err, status = http:request({
                method = "GET",
                path = "/test",
                --headers = ngx.req.get_headers(),
            })

            if not res then
                ngx.status = status
                ngx.say(err)
                return ngx.exit(ngx.status)
            end

            local body = res:read_body()


            local ok, err = http:set_keepalive(100,100)
            if not ok then
                ngx.say(err)
            end

            ngx.sleep(0.1)

            local res, err = http:request({
                method = "GET",
                path = "/test",
                headers = ngx.req.get_headers(),
            })

            local reuse = http:get_reused_times()
            ngx.say(reuse)

        ';
    }
    location = /test {
       content_by_lua '
            ngx.say("ok")
       ';
    }

--- request
GET /a
--- response_body
0

=== TEST 7: Do not retry with streamed request body
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
            test_api:add_host("primary", { id="a", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 10 })
            test_api:add_host("secondary", { id="b", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 10 })
    ';
}
--- log_level: debug
--- config
    location = /a {
        content_by_lua '
            local client_body_reader, err = http:get_client_body_reader()
            local res, err, status = http:request({
                method = ngx.req.get_method(),
                path = "/test",
                body = client_body_reader,
                headers = ngx.req.get_headers(),
            })

            if not res then
                ngx.status = status
                ngx.say(err)
                return ngx.exit(status)
            end

            ngx.say("Fail")

        ';
    }
    location = /test {
        content_by_lua '
            local first = ngx.shared.test_upstream:get("first_flag")

            if not first then
                ngx.shared.test_upstream:set("first_flag", true)
                ngx.status = 500
                return ngx.exit(500)
            end

            ngx.say("response")
        ';
    }
--- request
POST /a
Hello World
--- error_code: 502
--- response_body
500
