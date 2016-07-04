# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * 44;

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
        test_api:set_method("primary", "hash")

};

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';

no_long_string();
#no_diff();

run_tests();

__DATA__

=== TEST 1: Hash method, single host
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
        test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT })
    ';
}
--- log_level: debug
--- config
    location = / {
        content_by_lua '
                local sock, info = upstream:connect()
                if not sock then
                    ngx.log(ngx.ERR, info)
                else
                    ngx.say(info.host.id)
                    sock:setkeepalive()
                end

                upstream:process_failed_hosts()
        ';
    }
--- request
GET /
--- no_error_log
[error]
[warn]
--- response_body
1

=== TEST 2: Hash between multiple hosts, default settings
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
        test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT })
        test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT })
    ';
}
--- log_level: debug
--- config
    location = / {
        content_by_lua '
                local sock, info = upstream:connect(nil)
                if not sock then
                    ngx.log(ngx.ERR, info)
                else
                    ngx.say(info.host.id)
                    sock:setkeepalive()
                end


                upstream:process_failed_hosts()
        ';
    }
--- request
GET /
--- no_error_log
[error]
[warn]
--- response_body
1

=== TEST 2b: Hash between multiple hosts, provide a user-defined key
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
        test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT })
        test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT })
    ';
}
--- log_level: debug
--- config
    location = / {
        content_by_lua '
				local sock = nil
				local key  = "1.2.3.4" -- i know this will hash to 2 from trial and error. hooray unit tests!

                local sock, info = upstream:connect(sock, key)
                if not sock then
                    ngx.log(ngx.ERR, info)
                else
                    ngx.say(info.host.id)
                    sock:setkeepalive()
                end

                upstream:process_failed_hosts()
        ';
    }
--- request
GET /
--- no_error_log
[error]
[warn]
--- response_body
2

=== TEST 3: Hash is consistent
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
        test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT })
        test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT })
    ';
}
--- log_level: debug
--- config
    location = / {
        content_by_lua '

                local count = 10
                for i=1,count do
                    local sock, info = upstream:connect()
                    if not sock then
                        ngx.log(ngx.ERR, info)
                    else
                        ngx.print(info.host.id)
                        sock:setkeepalive()
                    end
                end

                upstream:process_failed_hosts()
        ';
    }
--- request
GET /
--- no_error_log
[error]
[warn]
--- response_body: 1111111111

=== TEST 4: Hash with user provided weights
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
        test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1 })
        test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1 })
    ';
}
--- log_level: debug
--- config
    location = / {
        content_by_lua '

                local count = 10
                for i=1,count do
                    local sock, info = upstream:connect()
                    if not sock then
                        ngx.log(ngx.ERR, info)
                    else
                        ngx.print(info.host.id)
                        sock:setkeepalive()
                    end
                end

                upstream:process_failed_hosts()
        ';
    }
--- request
GET /
--- no_error_log
[error]
[warn]
--- response_body: 1111111111

=== TEST 5: Weighted hash is consistent
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
        test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 2 })
        test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1 })
    ';
}
--- log_level: debug
--- config
    location = / {
        content_by_lua '

                local count = 10
                for i=1,count do
                    local sock, info = upstream:connect()
                    if not sock then
                        ngx.log(ngx.ERR, info)
                    else
                        ngx.print(info.host.id)
                        sock:setkeepalive()
                    end
                end

                upstream:process_failed_hosts()
        ';
    }
--- request
GET /
--- no_error_log
[error]
[warn]
--- response_body: 2222222222

=== TEST 5b: Weighted hash is consistent, odd number of hosts
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
        test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 10 })
        test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 20 })
        test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 30 })
        test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 40 })
        test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 50 })
    ';
}
--- log_level: debug
--- config
    location = / {
        content_by_lua '

                local count = 20
                for i=1,count do
                    local sock, info = upstream:connect()
                    if not sock then
                        ngx.log(ngx.ERR, info)
                    else
                        ngx.print(info.host.id)
                        sock:setkeepalive()
                    end
                end

                upstream:process_failed_hosts()
        ';
    }
--- request
GET /
--- no_error_log
[error]
[warn]
--- response_body: 33333333333333333333

=== TEST 5c: Weighted hash is consistent, last host has highest weight
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
        test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1 })
        test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 2 })
    ';
}
--- log_level: debug
--- config
    location = / {
        content_by_lua '

                local count = 10
                for i=1,count do
                    local sock, info = upstream:connect()
                    if not sock then
                        ngx.log(ngx.ERR, info)
                    else
                        ngx.print(info.host.id)
                        sock:setkeepalive()
                    end
                end

                upstream:process_failed_hosts()
        ';
    }
--- request
GET /
--- no_error_log
[error]
[warn]
--- response_body: 2222222222

=== TEST 6: Weighted hash is consistent, divisable weights
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
        test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 20 })
        test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 10 })
    ';
}
--- log_level: debug
--- config
    location = / {
        content_by_lua '

                local count = 10
                for i=1,count do
                    local sock, info = upstream:connect()
                    if not sock then
                        ngx.log(ngx.ERR, info)
                    else
                        ngx.print(info.host.id)
                        sock:setkeepalive()
                    end
                end

                upstream:process_failed_hosts()
        ';
    }
--- request
GET /
--- no_error_log
[error]
[warn]
--- response_body: 1111111111

=== TEST 7: Hash is consistent, re-keyed, and consistent
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
        test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT })
        test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT })
    ';
}
--- log_level: debug
--- config
    location = / {
        content_by_lua '

                local count = 10
                for i=1,count do
                    local sock, info = upstream:connect()
                    if not sock then
                        ngx.log(ngx.ERR, info)
                    else
                        ngx.print(info.host.id)
                        sock:setkeepalive()
                    end
                end

                upstream:process_failed_hosts()

				test_api:down_host("primary", 1)

                local count = 10
                for i=1,count do
                    local sock, info = upstream:connect()
                    if not sock then
                        ngx.log(ngx.ERR, info)
                    else
                        ngx.print(info.host.id)
                        sock:setkeepalive()
                    end
                end
        ';
    }

--- request
GET /
--- no_error_log
[error]
[warn]
--- response_body: 11111111112222222222

=== TEST 7b: Hash is consistent, re-keyed, consistent, re-keyed again, and consistent
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
        test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT })
        test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT })
        test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT })
        test_api:add_host("primary", { host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT })
    ';
}
--- log_level: debug
--- config
    location = / {
        content_by_lua '

                local count = 10
                for i=1,count do
                    local sock, info = upstream:connect()
                    if not sock then
                        ngx.log(ngx.ERR, info)
                    else
                        ngx.print(info.host.id)
                        sock:setkeepalive()
                    end
                end

				test_api:down_host("primary", 1)

                upstream:process_failed_hosts()

                local count = 10
                for i=1,count do
                    local sock, info = upstream:connect()
                    if not sock then
                        ngx.log(ngx.ERR, info)
                    else
                        ngx.print(info.host.id)
                        sock:setkeepalive()
                    end
                end

                upstream:process_failed_hosts()

				test_api:up_host("primary", 1)

                local count = 10
                for i=1,count do
                    local sock, info = upstream:connect()
                    if not sock then
                        ngx.log(ngx.ERR, info)
                    else
                        ngx.print(info.host.id)
                        sock:setkeepalive()
                    end
                end
        ';
    }

--- request
GET /
--- no_error_log
[error]
[warn]
--- response_body: 111111111144444444441111111111

