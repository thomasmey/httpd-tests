use strict;
use warnings FATAL => 'all';

use Apache::Test;
use Apache::TestConfig;
use IPC::Open3;
my $vars = Apache::Test::vars();

plan tests => ($vars->{ssl_module_name} ? 5 : 2);

sub run_and_gather_output {
    my $command = shift;
    my ($cin, $cout, $cerr) = (0, 0, 0);
    my $pid = open3($cin, $cout, $cerr, $command);
    waitpid( $pid, 0 );
    my $status = $? >> 8;
    my @cstdout = <$cout>;
    my @cstderr = <$cerr>;
    return { status => $status, stdout => \@cstdout, stderr => \@cstderr };
}

my $cfg = Apache::TestConfig->new(());
my $ab_path = "$cfg->{httpd_basedir}" . "/bin/ab";

my $http_url = Apache::TestRequest::module2url("core", {scheme => 'http', path => '/'});
my $http_results = run_and_gather_output("$ab_path -q -n 10 $http_url");
ok ($http_results->{status} == 0);
ok (scalar(@{$http_results->{stderr}}) == 0);

if ($vars->{ssl_module_name}) {
    my $https_url = Apache::TestRequest::module2url($vars->{ssl_module_name}, {scheme => 'https', path => '/'});
    my $https_results = run_and_gather_output("$ab_path -q -n 10 $https_url");
    ok ($https_results->{status} == 0);
    ok (scalar(@{$https_results->{stderr}}) == 0);

    #XXX: For some reason, stderr is getting pushed into stdout. This test will at least catch known SSL failures
    ok (scalar(grep(/SSL.*(fail|err)/i, @{$https_results->{stdout}}) == 0) );
}
