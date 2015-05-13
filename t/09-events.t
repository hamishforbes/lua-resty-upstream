# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => 17;

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
=== TEST 1: Can bind to an event
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
    ';
}
--- log_level: debug
--- config
    location = /a {
        content_by_lua '

            local ok, err = upstream:bind("host_up", function(event) 
            end)
            if not ok then
                ngx.say(err)
            else
                ngx.say("OK")
            end
        ';
    }
--- request
GET /a
--- response_body
OK

=== TEST 1b: Cannot bind to a non-existent event
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
    ';
}
--- log_level: debug
--- config
    location = /a {
        content_by_lua '

            local ok, err = upstream:bind("foobar", function(event) 
            end)
            if not ok then
                ngx.say(err)
            end
        ';
    }
--- request
GET /a
--- response_body
Event not found

=== TEST 2: Can't bind a string
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
    ';
}
--- log_level: debug
--- config
    location = /a {
        content_by_lua '

            local ok, err = upstream:bind("host_down", "foobar")
            if not ok then
                ngx.say(err)
            end
        ';
    }
--- request
GET /a
--- response_body
Can only bind a function

=== TEST 2b: Can't bind a table
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
    ';
}
--- log_level: debug
--- config
    location = /a {
        content_by_lua '

            local ok, err = upstream:bind("host_down", {})
            if not ok then
                ngx.say(err)
            end
        ';
    }
--- request
GET /a
--- response_body
Can only bind a function

=== TEST 3: bind passes through http upstream
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
    ';
}
--- log_level: debug
--- config
    location = /a {
        content_by_lua '
            local upstream_http  = require("resty.upstream.http")
            http = upstream_http:new(upstream)

            local ok, err = http:bind("host_down", function(e) end )
            if not ok then
                ngx.say(err)
            else
                ngx.say("OK")
            end
        ';
    }
--- request
GET /a
--- response_body
OK

=== TEST 4: host_down event fires
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
        test_api:add_host("primary", { id="a", host = "127.0.0.1", port = 8$TEST_NGINX_SERVER_PORT, weight = 1, max_fails = 1 })
    ';
}
--- config
    location = / {
        content_by_lua '
            -- Bind event
            local function host_down_handler(event)
                ngx.say("host_down fired!")
                local cjson = require("cjson")
                local log = {
                    host_id = event.host.id,
                    host = event.host.host,
                    host_max_fails = event.host.max_fails,
                    host_up = event.host.up,
                    pool = event.pool.id
                }
                ngx.say(cjson.encode(log))
            end
            local ok, err = upstream:bind("host_down", host_down_handler)
            if not ok then
                ngx.say(err)
            end

            -- Simulate 2 connection attempts
            for i=1,3 do
                upstream:connect()
                -- Run process_failed_hosts inline rather than after the request is done
                upstream._process_failed_hosts(false, upstream, upstream:ctx())
            end

        ';
    }
--- request
GET /
--- response_body
host_down fired!
{"host":"127.0.0.1","host_id":"a","pool":"primary","host_up":false}

=== TEST 5: host_up event fires
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
        test_api:add_host("primary", { id="b", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1, max_fails = 1, up = false, lastfail = 1 })
    ';
}
--- config
    location = / {
        content_by_lua '
            -- Bind event
            local function host_up_handler(event)
                ngx.say("host_up fired!")
                local cjson = require("cjson")
                local log = {
                    host_id = event.host.id,
                    host = event.host.host,
                    host_max_fails = event.host.max_fails,
                    host_up = event.host.up,
                    pool = event.pool.id
                }
                ngx.say(cjson.encode(log))
            end
            local ok, err = upstream:bind("host_up", host_up_handler)
            if not ok then
                ngx.say(err)
            end

            -- Run background func inline rather than after the request is done
            upstream:revive_hosts()

        ';
    }
--- request
GET /
--- no_error_log: error
--- response_body
host_up fired!
{"host":"127.0.0.1","host_id":"b","pool":"primary","host_up":true}

=== TEST 6: host_up event does not fire when reseting failcount
--- http_config eval
"$::HttpConfig"
."$::InitConfig"
. q{
        test_api:add_host("primary", { id="b", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1, failcount = 1, max_fails = 2, lastfail = 1 })
    ';
}
--- config
    location = / {
        content_by_lua '
            -- Bind event
            local function host_up_handler(event)
                ngx.say("host_up fired!")
                local cjson = require("cjson")
                local log = {
                    host_id = event.host.id,
                    host = event.host.host,
                    host_max_fails = event.host.max_fails,
                    host_up = event.host.up,
                    pool = event.pool.id
                }
                ngx.say(cjson.encode(log))
            end
            local ok, err = upstream:bind("host_up", host_up_handler)
            if not ok then
                ngx.say(err)
            end

            -- Run background func inline rather than after the request is done
            upstream:revive_hosts()

        ';
    }
--- request
GET /
--- response_body_unlike
host_up fired!
