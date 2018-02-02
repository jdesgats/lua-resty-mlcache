# vim:set ts=4 sts=4 sw=4 et:

use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

workers(2);

#repeat_each(2);

plan tests => repeat_each() * (blocks() * 3);

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;;";
    lua_shared_dict  cache_shm 1m;
    lua_shared_dict  ipc_shm 1m;

    init_by_lua_block {
        -- local verbose = true
        local verbose = false
        local outfile = "$Test::Nginx::Util::ErrLogFile"
        -- local outfile = "/tmp/v.log"
        if verbose then
            local dump = require "jit.dump"
            dump.on(nil, outfile)
        else
            local v = require "jit.v"
            v.on(outfile)
        end

        require "resty.core"
        -- jit.opt.start("hotloop=1")
        -- jit.opt.start("loopunroll=1000000")
        -- jit.off()
    }
};

run_tests();

__DATA__

=== TEST 1: l1_serializer is called on cache misses
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                l1_serializer = function(s)
                    return string.format("transform(%q)", s)
                end,
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local data, err = cache:get("key", nil, function() return "foo" end)
            if not data then
                ngx.say(err)
            end
            ngx.say(data)
        }
    }
--- request
GET /t
--- response_body
transform("foo")
--- no_error_log
[error]



=== TEST 2: l1_serializer is not called on L1 hits
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local calls = 0
            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                l1_serializer = function(s)
                    calls = calls + 1
                    return string.format("transform(%q)", s)
                end,
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            for i=1, 3 do
                local data, err = cache:get("key", nil, function() return "foo" end)
                if not data then
                    ngx.say(err)
                end
                ngx.say(data)
            end
            ngx.say("calls: ", calls)
        }
    }
--- request
GET /t
--- response_body
transform("foo")
transform("foo")
transform("foo")
calls: 1
--- no_error_log
[error]



=== TEST 3: l1_serializer is called on L2 hits
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local calls = 0
            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                l1_serializer = function(s)
                    calls = calls + 1
                    return string.format("transform(%q)", s)
                end,
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            for i=1, 3 do
                local data, err = cache:get("key", nil, function() return "foo" end)
                if not data then
                    ngx.say(err)
                end
                ngx.say(data)
                cache.lru:delete("key")
            end
            ngx.say("calls: ", calls)
        }
    }
--- request
GET /t
--- response_body
transform("foo")
transform("foo")
transform("foo")
calls: 3
--- no_error_log
[error]



=== TEST 4: l1_serializer is called in protected mode (L2 miss)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                l1_serializer = function(s)
                    error("cannot transform")
                end,
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local data, err = cache:get("key", nil, function() return "foo" end)
            if not data then
                ngx.say(err)
            end
            ngx.say(data)
        }
    }
--- request
GET /t
--- response_body_like
l1_serializer threw an error: .*?: cannot transform
--- no_error_log
[error]



=== TEST 5: l1_serializer is called in protected mode (L2 hit)
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local called = false
            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                l1_serializer = function(s)
                    if called then error("cannot transform") end
                    called = true
                    return string.format("transform(%q)", s)
                end,
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            assert(cache:get("key", nil, function() return "foo" end))
            cache.lru:delete("key")

            local data, err = cache:get("key", nil, function() return "foo" end)
            if not data then
                ngx.say(err)
            end
            ngx.say(data)
        }
    }
--- request
GET /t
--- response_body_like
l1_serializer threw an error: .*?: cannot transform
--- no_error_log
[error]



=== TEST 6: l1_serializer is not supposed to return a nil value
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                l1_serializer = function(s)
                    return nil
                end,
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local ok, err = cache:get("key", nil, function() return "foo" end)
            assert(not ok, "get call returned successfully")
            ngx.say(err)
        }
    }
--- request
GET /t
--- response_body_like
l1_serializer returned a nil value
--- no_error_log
[error]



=== TEST 7: l1_serializer can return an error
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                l1_serializer = function(s)
                    return nil, "cannot transform"
                end,
            })
            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local data, err = cache:get("key", nil, function() return "foo" end)
            if not data then
                ngx.say(err)
            end
            ngx.say(data)
        }
    }
--- request
GET /t
--- response_body
l1_serializer returned an error: cannot transform
nil
--- no_error_log
[error]



=== TEST 8: l1_serializer can be given as a :get() parameter
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm")

            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local data, err = cache:get("key", {
                l1_serializer = function(s)
                    return string.format("transform(%q)", s)
                end
            }, function() return "foo" end)
            if not data then
                ngx.say(ngx.ERR, err)
            end
            ngx.say(data)
        }
    }
--- request
GET /t
--- response_body
transform("foo")
--- no_error_log
[error]



=== TEST 9: l1_serializer as a :get() parameter has precedence over the constructor one
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                l1_serializer = function(s)
                    return string.format("constructor(%q)", s)
                end
            })

            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local data, err = cache:get("key1", {
                l1_serializer = function(s)
                    return string.format("get_parameter(%q)", s)
                end
            }, function() return "foo" end)
            if not data then
                ngx.say(ngx.ERR, err)
            end
            ngx.say(data)

            local data, err = cache:get("key2", nil, function() return "bar" end)
            if not data then
                ngx.say(ngx.ERR, err)
            end
            ngx.say(data)
        }
    }
--- request
GET /t
--- response_body
get_parameter("foo")
constructor("bar")
--- no_error_log
[error]



=== TEST 10: l1_serializer is called for set calls
--- http_config eval: $::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            local mlcache = require "resty.mlcache"

            local cache, err = mlcache.new("my_mlcache", "cache_shm", {
                ipc_shm = "ipc_shm",
            })

            if not cache then
                ngx.log(ngx.ERR, err)
                return
            end

            local called = false
            local ok, err = cache:set("key", {
                l1_serializer = function(s)
                    called = true
                    return string.format("transform(%q)", s)
                end
            }, "value")

            if not ok then
                ngx.say(err)
            end
            ngx.say(tostring(called))

            local value, err = cache:get("key", nil, error)
            if not value then
                ngx.say(err)
            end
            ngx.say(value)
        }
    }
--- request
GET /t
--- response_body
true
transform("value")
--- no_error_log
[error]
