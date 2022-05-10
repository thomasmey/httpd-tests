use strict;
use warnings FATAL => 'all';

use Apache::Test;
use Apache::TestRequest;
use Apache::TestUtil;

my @ts = (
   # see t/conf/extra.conf.in
   { url => "/apache/sed/out-foo/foobar.html", content => 'barbar', msg => "sed output filter", code => 200 },
   { url => "/apache/sed-echo/echo.html", content => 'barbar', msg => "sed input filter", code => 200, body=>"foobar" }
);

my $tests = 2*scalar @ts;

plan tests => $tests, need_module('sed');


for my $t (@ts) {
  my $req;
  if (defined($t->{'body'})) { 
    $req = POST  $t->{'url'}, content => $t->{'body'};
  }
  else { 
    $req = GET $t->{'url'};
  }
  ok t_cmp($req->code, $t->{'code'}, "status code for " . $t->{'url'});
  my $content = $req->content;
  chomp($content);
  ok t_cmp($content, $t->{content}, $t->{msg});
}


