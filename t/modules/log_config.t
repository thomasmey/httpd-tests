use strict;
use warnings FATAL => 'all';

use Apache::Test;
use Apache::TestRequest;
use Apache::TestUtil;
use Apache::TestConfig ();

my $config = Apache::Test::config();
my $hostport = Apache::TestRequest::hostport();

plan tests => 3, ['log_config'];

Apache::TestRequest::module("mod_log_config");
         
# my $sock = Apache::TestRequest::vhost_socket();
# ok $sock && $sock->connected;

# TODOs:
# replace ok checks with checks if all log entries were written correctly

my $r = GET("http://username:password\@localhost/test");
ok t_cmp($r->code, 200, "non-cached call to index.html");

$r = GET("/?q=dddd");
ok t_cmp($r->code, 200, "call to cache index.html");

$r = GET("/cache/");
ok t_cmp($r->code, 200, "cached call to index.html");
