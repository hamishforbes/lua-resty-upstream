# Load Balancer example

This openresty config and lua script show an example of a simple HTTP load balancer using lua-resty-upstream and lua-resty-http.

## init_by_lua

In `init_by_lua` we've pulled in all 3 upstream modules, socket, http and api.

Then we create a new socket upstream instance and define 2 pools, `primary` and `dr`, each with 2 hosts.
Set the IPs and ports to whatever is appropriate for your environment.
The pools have some keepalive and timeout settings configured

Instances are created for both the API and http upstream modules.

Repeat for the SSL enable origin servers.

## init_worker_by_lua

We call `init_background_thread()` here on both http upstream instances to start the background workers.

This worker will restore dead hosts after the defined timeout period and perform background checks on hosts.


## lua-load-balancer

In our main server block, listening on port 80 and on port 443 for ssl, we pass everything to `load-balancer.lua` in `content_by_lua`.

In `load-balancer.lua` we check the scheme variable and select the right upstream instance.
`httpc` can then be used as if it was an instance of lua-resty-http.
The only real difference is the second return value from `request()` is a table.

We first get the request body iterator and return a 411 error if the client is attempting to send a chunked request.
This is not yet supported by the ngx_lua `ngx.req.socket` api.

Then we make an http request with all the parameters of the current request.
If the request errors then the `conn_info` table will contain the error message in `err` and the recommended response status code in `status`.
This will be `504 Gateway Timeout` if no tcp connection could be made at all, or `502 Bad Gateway` if the upstream host returned a bad status code.

You don't *have* to use these status codes, you can do whatever you like at this point.

If we successfully made a request to one of the hosts then we strip out hop-by-hop headers and add the rest of the upstream response headers to the current request's response headers.
Then we read the response body, if available, from the upstream host in chunks and flush back to the client.

We call `set_keepalive()` to let the pool configuration and http response determine whether to close the socket or put it into the connection pool.

Lastly we call `process_failed_hosts()` on the socket upstream module to save any failed hosts back to the dictionary.
This function triggers an immediate callback to run once the request has finished and so this doesn't affect the response time for the client.

## api

On port 8080 theres a very simple HTTP API, requesting `/pools` will return the current json encoded pool definition.
Calling `/down_host/primary/1` will mark the first host in the primary pool as offline and immediately stop any further requests being made to it.
Likewise `/up_host/primary/1` will bring it back up.
