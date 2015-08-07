# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket;
use Cwd qw(cwd);

plan tests => repeat_each() * (16);

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
        test_api:set_priority("primary", 5)
        test_api:add_host("primary", { id="a", host = "127.0.0.1", port = 80, weight = 1 })
    ';
};

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';

no_long_string();
#no_diff();

run_tests();

__DATA__
=== TEST 1: Cannot add pool while pools locked
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local pools, err = test_api:get_locked_pools()

            local ok, err = test_api:create_pool({id = "secondary", timeout = 100, priority = 10})
            ngx.say(err)

            local ok, err = test_api:unlock_pools()
            local pools = cjson.decode(upstream.dict:get(upstream.pools_key))
            for k,v in pairs(pools) do
                ngx.say(k)
            end
        ';
    }
--- request
GET /a
--- response_body
locked
primary


=== TEST 2: Cannot set pool priority while pools locked
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local pools, err = test_api:get_locked_pools()

            local ok, err = test_api:set_priority("secondary", 11)
            ngx.say(err)

            local ok, err = test_api:unlock_pools()

            local pools = cjson.decode(upstream.dict:get(upstream.pools_key))
            ngx.say(pools.primary.priority)

        ';
    }
--- request
GET /a
--- response_body
locked
5


=== TEST 3: Cannot add host while pools locked
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local pools, err = test_api:get_locked_pools()

            local ok, err = test_api:add_host("primary", { id="b", host = "127.0.0.1", port = $TEST_NGINX_SERVER_PORT, weight = 1 })
            ngx.say(err)

            local ok, err = test_api:unlock_pools()
            local pools = cjson.decode(upstream.dict:get(upstream.pools_key))
            for k,v in pairs(pools.primary.hosts) do
                ngx.say(pools.primary.hosts[k].id)
            end
        ';
    }
--- request
GET /a
--- response_body
locked
a


=== TEST 4: Cannot remove host while pools locked
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local pools, err = test_api:get_locked_pools()

            local ok, err = test_api:remove_host("primary", "a")
            ngx.say(err)

            local ok, err = test_api:unlock_pools()
            local pools = cjson.decode(upstream.dict:get(upstream.pools_key))
            for k,v in pairs(pools.primary.hosts) do
               ngx.say(pools.primary.hosts[k].id)
            end
        ';
    }
--- request
GET /a
--- response_body
locked
a

=== TEST 5: Cannot set host weight while pools locked
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local pools, err = test_api:get_locked_pools()

            local ok, err = test_api:set_weight("primary", "a", 11)
            ngx.say(err)

            local ok, err = test_api:unlock_pools()

            local pools = cjson.decode(upstream.dict:get(upstream.pools_key))
            ngx.say(pools.primary.hosts[upstream.get_host_idx("a", pools.primary.hosts)].weight)
        ';
    }
--- request
GET /a
--- response_body
locked
1


=== TEST 6: Cannot set host down while pools locked
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local pools, err = test_api:get_locked_pools()

            local ok, err = test_api:down_host("primary", "a")
            ngx.say(err)

            local ok, err = test_api:unlock_pools()
            ngx.say(pools.primary.hosts[upstream.get_host_idx("a", pools.primary.hosts)].up)
        ';
    }
--- request
GET /a
--- response_body
locked
true


=== TEST 7: Cannot set host up while pools locked
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            test_api:down_host("primary", "a")
            local pools, err = test_api:get_locked_pools()

            local ok, err = test_api:up_host("primary", "a")
            ngx.say(err)

            local ok, err = test_api:unlock_pools()
            ngx.say(pools.primary.hosts[upstream.get_host_idx("a", pools.primary.hosts)].up)
        ';
    }
--- request
GET /a
--- response_body
locked
false


=== TEST 8: revive_hosts returns nil when locked
--- http_config eval: $::HttpConfig
--- config
    location = /a {
        content_by_lua '
            local pools, err = upstream:get_locked_pools()

            local ok, err = upstream:revive_hosts()
            if not ok then
                ngx.say(err)
            else
                ngx.say("wat")
            end

            local ok, err = upstream:unlock_pools()
        ';
    }
--- request
GET /a
--- response_body
locked
