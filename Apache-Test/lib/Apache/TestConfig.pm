package Apache::TestConfig;

use strict;
use warnings FATAL => 'all';

use constant WIN32   => $^O eq 'MSWin32';
use constant CYGWIN  => $^O eq 'cygwin';
use constant NETWARE => $^O eq 'NetWare';
use constant WINFU   => WIN32 || CYGWIN || NETWARE;

use File::Copy ();
use File::Find qw(finddepth);
use File::Spec::Functions qw(catfile abs2rel splitdir
                             catdir file_name_is_absolute);
use Cwd qw(fastcwd);

use Apache::TestConfigPerl ();
use Apache::TestConfigParse ();
use Apache::TestTrace;
use Apache::TestServer ();
use Socket ();

our %Usage = (
   top_dir       => 'top-level directory (default is $PWD)',
   t_dir         => 'the t/ test directory (default is $top_dir/t)',
   t_conf        => 'the conf/ test directory (default is $t_dir/conf)',
   t_logs        => 'the logs/ test directory (default is $t_dir/logs)',
   t_conf_file   => 'test httpd.conf file (default is $t_conf/httpd.conf)',
   src_dir       => 'source directory to look for mod_foos.so',
   serverroot    => 'ServerRoot (default is $t_dir)',
   documentroot  => 'DocumentRoot (default is $ServerRoot/htdocs',
   port          => 'Port (default is 8529)',
   servername    => 'ServerName (default is localhost)',
   user          => 'User to run test server as (default is $USER)',
   group         => 'Group to run test server as (default is $GROUP)',
   bindir        => 'Apache bin/ dir (default is apxs -q BINDIR)',
   sbindir       => 'Apache sbin/ dir (default is apxs -q SBINDIR)',
   httpd         => 'server to use for testing (default is $bindir/httpd)',
   target        => 'name of server binary (default is apxs -q TARGET)',
   apxs          => 'location of apxs (default is from Apache::BuildConfig)',
   httpd_conf    => 'inherit config from this file (default is apxs derived)',
   maxclients    => 'maximum number of concurrent clients (default is 1)',
   perlpod       => 'location of perl pod documents (for testing downloads)',
);

sub usage {
    for my $hash (\%Usage) {
        for (sort keys %$hash){
            printf "   -%-16s %s\n", $_, $hash->{$_};
        }
    }
}

sub filter_args {
    my($args, $wanted_args) = @_;
    my(@pass, %keep);

    my @filter = @$args;

    if (ref($filter[0])) {
        push @pass, shift @filter;
    }

    while (my($key, $val) = splice @filter, 0, 2) {
        if ($wanted_args->{$key}) {
            $keep{$key} = $val;
        }
        else {
            push @pass, $key, $val;
        }
    }

    return (\@pass, \%keep);
}

my %passenv = map { $_,1 } qw{
APXS APACHE APACHE_GROUP APACHE_USER APACHE_PORT
};

sub passenv {
    \%passenv;
}

sub passenv_makestr {
    my @vars;

    for (keys %passenv) {
        push @vars, "$_=\$($_)";
    }

    "@vars";
}

sub server { shift->{server} }

sub modperl_build_config {
    eval {
        require Apache::Build;
    } or return undef;
    return Apache::Build->build_config;
}

sub new_test_server {
    my($self, $args) = @_;
    Apache::TestServer->new($args || $self)
}

sub new {
    my $class = shift;
    my $args;

    $args = shift if $_[0] and ref $_[0];

    $args = $args ? {%$args} : {@_}; #copy

    #see Apache::TestMM::{filter_args,generate_script}
    #we do this so 'perl Makefile.PL' can be passed options such as apxs
    #without forcing regeneration of configuration and recompilation of c-modules
    #as 't/TEST apxs /path/to/apache/bin/apxs' would do
    while (my($key, $val) = each %Apache::TestConfig::Argv) {
        $args->{$key} = $val;
    }

    my $thaw = {};

    #thaw current config
    for (qw(conf t/conf)) {
        last if eval {
            require "$_/apache_test_config.pm";
            $thaw = 'apache_test_config'->new;
            delete $thaw->{save};
        };
    };

    if ($args->{thaw} and ref($thaw) ne 'HASH') {
        #dont generate any new config
        $thaw->{vars}->{$_} = $args->{$_} for keys %$args;
        $thaw->{server} = $thaw->new_test_server;
        $thaw->add_inc;
        return $thaw;
    }

    #regenerating config, so forget old
    if ($args->{save}) {
        for (qw(vhosts inherit_config modules inc)) {
            delete $thaw->{$_} if exists $thaw->{$_};
        }
    }

    my $self = bless {
        clean => {},
        vhosts => {},
        inherit_config => {},
        modules => {},
        inc => [],
        %$thaw,
        mpm => "",
        httpd_defines => {},
        vars => $args,
        postamble => [],
        preamble => [],
        postamble_hooks => [],
        preamble_hooks => [],
    }, ref($class) || $class;

    my $vars = $self->{vars}; #things that can be overridden

    for (qw(save verbose)) {
        next unless exists $args->{$_};
        $self->{$_} = delete $args->{$_};
    }

    $vars->{top_dir} ||= fastcwd;
    $vars->{top_dir} = pop_dir($vars->{top_dir}, 't');

    $self->add_inc;

    #help to find libmodperl.so
    my $src_dir = catfile $vars->{top_dir}, qw(src modules perl);
    $vars->{src_dir}      ||= $src_dir if -d $src_dir;

    $vars->{t_dir}        ||= catfile $vars->{top_dir}, 't';
    $vars->{serverroot}   ||= $vars->{t_dir};
    $vars->{documentroot} ||= catfile $vars->{serverroot}, 'htdocs';
    $vars->{perlpod}      ||= $self->find_in_inc('pod');
    $vars->{perl}         ||= $^X;
    $vars->{t_conf}       ||= catfile $vars->{serverroot}, 'conf';
    $vars->{t_logs}       ||= catfile $vars->{serverroot}, 'logs';
    $vars->{t_conf_file}  ||= catfile $vars->{t_conf},   'httpd.conf';

    $vars->{scheme}       ||= 'http';
    $vars->{servername}   ||= $self->default_servername;
    $vars->{port}         ||= $self->default_port;

    $vars->{user}         ||= $self->default_user;
    $vars->{group}        ||= $self->default_group;
    $vars->{serveradmin}  ||= $self->default_serveradmin;
    $vars->{maxclients}   ||= 1;
    $vars->{proxy}        ||= 'off';

    $self->configure_apxs;
    $self->configure_httpd;
    $self->inherit_config; #see TestConfigParse.pm
    $self->configure_httpd_eapi; #must come after inherit_config

    $self->default_module(cgi    => [qw(mod_cgi mod_cgid)]);
    $self->default_module(thread => [qw(worker threaded)]);

    $self->{hostport} = $self->hostport;

    $self->{server} = $self->new_test_server;

    $self;
}

sub default_module {
    my($self, $name, $choices) = @_;

    $name .= '_module';

    ($self->{vars}->{$name}) = grep {
        $self->{modules}->{$_};
    } map "$_.c", @$choices;

    $self->{vars}->{$name} ||= 0;
}

sub configure_apxs {
    my $self = shift;

    $self->{APXS} = $self->default_apxs;

    return unless $self->{APXS};

    my $vars = $self->{vars};

    $vars->{bindir}   ||= $self->apxs('BINDIR', 1);
    $vars->{sbindir}  ||= $self->apxs('SBINDIR');
    $vars->{target}   ||= $self->apxs('TARGET');
    $vars->{conf_dir} ||= $self->apxs('SYSCONFDIR');

    if ($vars->{conf_dir}) {
        $vars->{httpd_conf} ||= catfile $vars->{conf_dir}, 'httpd.conf';
    }
}

sub configure_httpd {
    my $self = shift;
    my $vars = $self->{vars};

    $vars->{target} ||= 'httpd';

    unless ($vars->{httpd}) {
        #sbindir should be bin/ with the default layout
        #but its eaiser to workaround apxs than fix apxs
        for my $dir (map { $vars->{$_} } qw(sbindir bindir)) {
            my $httpd = catfile $dir, $vars->{target};
            next unless -x $httpd;
            $vars->{httpd} = $httpd;
            last;
        }

        $vars->{httpd} ||= $self->default_httpd;
    }

    if ($vars->{httpd}) {
        my @chunks = splitdir $vars->{httpd};
        pop @chunks for 1..2; #bin/httpd
        $self->{httpd_basedir} = catfile @chunks;
    }

    #cleanup httpd droppings
    my $sem = catfile $vars->{t_logs}, 'apache_runtime_status.sem';
    unless (-e $sem) {
        $self->{clean}->{files}->{$sem} = 1;
    }
}

sub configure_httpd_eapi {
    my $self = shift;
    my $vars = $self->{vars};

    #deal with EAPI_MM_CORE_PATH if defined.
    if (defined($self->{httpd_defines}->{EAPI_MM_CORE_PATH})) {
        my $path = $self->{httpd_defines}->{EAPI_MM_CORE_PATH};

        #ensure the directory exists
        my @chunks = splitdir $path;
        pop @chunks; #the file component of the path
        $path = catdir @chunks;
        unless (file_name_is_absolute $path) {
            $path = catdir $vars->{serverroot}, $path;
        }
        $self->gendir($path);
    }
}

sub configure_proxy {
    my $self = shift;
    my $vars = $self->{vars};

    #if we proxy to ourselves, must bump the maxclients
    if ($vars->{proxy} =~ /^on$/i) {
        $vars->{maxclients}++;
        $vars->{proxy} = $self->{vhosts}->{'mod_proxy'}->{hostport};
        return $vars->{proxy};
    }

    return undef;
}

sub add_config {
    my $self = shift;
    my $where = shift;
    my($directive, $arg, $hash) = @_;
    my $args = "";

    if ($hash) {
        $args = "<$directive $arg>\n";
        if (ref($hash)) {
            while (my($k,$v) = each %$hash) {
                $args .= "   $k $v\n";
            }
        }
        else {
            $args .= "   $hash";
        }
        $args .= "</$directive>\n";
    }
    elsif (ref($directive) eq 'ARRAY') {
        $args = join "\n", @$directive;
    }
    else {
        $args = "$directive " .
          (ref($arg) && (ref($arg) eq 'ARRAY') ? "@$arg" : $arg || "");
    }

    push @{ $self->{$where} }, $args;
}

sub postamble {
    shift->add_config(postamble => @_);
}

sub preamble {
    shift->add_config(preamble => @_);
}

sub postamble_register {
    push @{ shift->{postamble_hooks} }, @_;
}

sub preamble_register {
    push @{ shift->{preamble_hooks} }, @_;
}

sub add_config_hooks_run {
    my($self, $where, $out) = @_;

    for (@{ $self->{"${where}_hooks"} }) {
        if ((ref($_) and ref($_) eq 'CODE') or $self->can($_)) {
            $self->$_();
        }
        else {
            print "WARNING: cannot run configure hook: `$_'\n";
        }
    }

    for (@{ $self->{$where} }) {
        $self->replace;
        print $out "$_\n";
    }
}

sub postamble_run {
    shift->add_config_hooks_run(postamble => @_);
}

sub preamble_run {
    shift->add_config_hooks_run(preamble => @_);
}

sub default_group {
    return if WINFU;

    my $gid = $);

    #use only first value if $) contains more than one
    $gid =~ s/^(\d+).*$/$1/;

    $ENV{APACHE_GROUP} || (getgrgid($gid) || "#$gid");
}

sub default_user {
    return if WINFU;

    my $uid = $>;

    my $user = $ENV{APACHE_USER} || (getpwuid($uid) || "#$uid");

    if ($user eq 'root') {
	my $other = (getpwnam('nobody'))[0];
        if ($other) {
            $user = $other;
        }
        else {
            die "cannot run tests as User root";
            #XXX: prompt for another username
        }
    }

    $user;
}

sub default_serveradmin {
    my $vars = shift->{vars};
    join '@', ($vars->{user} || 'unknown'), $vars->{servername};
}

sub default_apxs {
    my $self = shift;

    return $self->{vars}->{apxs} if $self->{vars}->{apxs};

    if (my $build_config = modperl_build_config()) {
        return $build_config->{MP_APXS};
    }

    $ENV{APXS} || which('apxs');
}

sub default_httpd {
    my $vars = shift->{vars};

    $ENV{APACHE} || which($vars->{target});
}

my $localhost;

sub default_localhost {
    my $localhost_addr = pack('C4', 127, 0, 0, 1);
    gethostbyaddr($localhost_addr, Socket::AF_INET()) || 'localhost';
}

sub default_servername {
    my $self = shift;
    $localhost ||= $self->default_localhost;
}

#XXX: could check if the port is in use and select another if so
sub default_port {
    $ENV{APACHE_PORT} || 8529;
}

sub default_loopback {
    '127.0.0.1';
}

sub port {
    my($self, $module) = @_;
    unless ($module) {
        my $vars = $self->{vars};
        return $vars->{port} unless $vars->{scheme} eq 'https';
        $module = 'mod_ssl';
    }
    return $self->{vhosts}->{$module}->{port};
}

sub hostport {
    my $self = shift;
    my $vars = shift || $self->{vars};
    my $module = shift || '';

    my $name = $vars->{servername};
    my $resolve = \$self->{resolved}->{$name};

    unless ($$resolve) {
        if (gethostbyname $name) {
            $$resolve = $name;
        }
        else {
            $$resolve = $self->default_loopback;
            warn "lookup $name failed, using $$resolve for client tests\n";
        }
    }

    join ':', $$resolve, $self->port($module);
}

#look for mod_foo.so
sub find_apache_module {
    my($self, $module) = @_;

    my $vars = $self->{vars};
    my $sroot = $vars->{serverroot};

    my @trys = grep { $_ }
      ($vars->{src_dir},
       $self->apxs('LIBEXECDIR'),
       catfile($sroot, 'modules'),
       catfile($sroot, 'libexec'));

    for (@trys) {
        my $file = catfile $_, $module;
        if (-e $file) {
            $self->trace("found $module => $file");
            return $file;
        }
    }
}

#generate files and directories

sub genwarning {
    my($self, $type) = @_;
    return unless $type;
    return "#WARNING: this file is generated, do not edit\n" .
           calls_trace();
}

sub calls_trace {
    my $frame = 1;
    my $trace = '';

    while (1) {
        my($package, $filename, $line) = caller($frame);
        last unless $filename;
        $trace .= "# $frame. $filename:$line\n";
        $frame++;
    }

    return $trace;
}

sub genfile {
    my($self, $file, $warn) = @_;

    my $name = abs2rel $file, $self->{vars}->{t_dir};
    $self->trace("generating $name");

    open my $fh, '>', $file or die "open $file: $!";

    if (my $msg = $self->genwarning($warn)) {
        print $fh $msg, "\n";
    }

    $self->{clean}->{files}->{$file} = 1;

    return $fh;
}

sub cpfile {
    my($self, $from, $to) = @_;
    File::Copy::copy($from, $to);
    $self->{clean}->{files}->{$to} = 1;
}

sub symlink {
    my($self, $from, $to) = @_;
    CORE::symlink($from, $to);
    $self->{clean}->{files}->{$to} = 1;
}

sub gendir {
    my($self, $dir) = @_;

    mkdir $dir, 0755 unless -d $dir;
    $self->{clean}->{dirs}->{$dir} = 1;
}

sub clean {
    my $self = shift;
    $self->{clean_level} = shift || 2; #2 == really clean, 1 == reconfigure

    $self->new_test_server->clean;
    $self->cmodules_clean;

    for (keys %{ $self->{clean}->{files} }) {
        if (-e $_) {
            $self->trace("unlink $_");
            unlink $_;
        }
        else {
            #print "unlink $_: $!\n";
        }
    }

    for (keys %{ $self->{clean}->{dirs} }) {
        if (-d $_) {
            opendir(my $dh, $_);
            my $notempty = grep { ! /^\.{1,2}$/ } readdir $dh;
            closedir $dh;
            next if $notempty;
            $self->trace("rmdir $_");
            rmdir $_;
        }
    }
}

sub replace {
    my $self = shift;
    s/@(\w+)@/$self->{vars}->{lc $1}/g;
}

#XXX: probably have too many ways todo this by now, ho-hum
sub configure_vhost {
    my($self, $pre, $module, $post) = @_;

    #don't allocate a port if this module is not configured
    if ($module =~ /^mod_/ and not $self->{modules}->{"$module.c"}) {
        return join '', $pre, $module, $post;
    }

    my $port = $self->new_vhost($module);

    join '', "Listen $port\n", $pre, $port, $post;
}

sub replace_vhost_modules {
    my $self = shift;
    #example: <VirtualHost _default_:mod_proxy>
    s{^(\s*<VirtualHost\s+_default_:)(\D+)(\s*>\s*)}
      {
          $self->configure_vhost($1, $2, $3);
      }ie;
}

sub replace_vars {
    my($self, $in, $out) = @_;

    local $_;
    while (<$in>) {
        $self->replace;
        $self->replace_vhost_modules;
        print $out $_;
    }
}

sub index_html_template {
    my $self = shift;
    return "welcome to $self->{server}->{name}\n";
}

sub generate_index_html {
    my $self = shift;
    my $dir = $self->{vars}->{documentroot};
    $self->gendir($dir);
    my $file = catfile $dir, 'index.html';
    return if -e $file;
    my $fh = $self->genfile($file);
    print $fh $self->index_html_template;
}

sub types_config_template {
    return <<EOF;
text/html  html htm
image/gif  gif
image/jpeg jpeg jpg jpe
image/png  png
text/plain asc txt
EOF
}

sub generate_types_config {
    my $self = shift;

    unless ($self->{inherit_config}->{TypesConfig}) {
        my $types = catfile $self->{vars}->{t_conf}, 'mime.types';
        unless (-e $types) {
            my $fh = $self->genfile($types, 1);
            print $fh $self->types_config_template;
            close $fh;
        }
        $self->postamble(TypesConfig => qq("$types"));
    }
}

sub httpd_conf_template {
    my($self, $try) = @_;

    if (open my $in, $try) {
        return $in;
    }
    else {
        return \*DATA;
    }
}

sub generate_extra_conf {
    my $self = shift;

    my(@extra_conf, @conf_in);

    finddepth(sub {
        return unless /\.conf\.in$/;
        push @conf_in, catdir $File::Find::dir, $_;
    }, $self->{vars}->{t_conf});

    for my $file (@conf_in) {
        (my $generated = $file) =~ s/\.in$//;
        push @extra_conf, $generated;

        notice "Including $generated config file";

        next if -e $generated;

        open(my $in, $file) or next;

        my $out = $self->genfile($generated, 1);
        $self->replace_vars($in, $out);

        close $in;
        close $out;
    }

    return \@extra_conf;
}

#XXX: just a quick hack to support t/TEST -ssl
#outside of httpd-test/perl-framework
sub generate_ssl_conf {
    my $self = shift;
    my $vars = $self->{vars};
    my $conf = "$vars->{t_conf}/ssl";
    my $httpd_test_ssl = "../httpd-test/perl-framework/t/conf/ssl";
    my $ssl_conf = "$vars->{top_dir}/$httpd_test_ssl";

    if (-d $ssl_conf and not -d $conf) {
        $self->gendir($conf);
        for (qw(ssl.conf.in)) {
            $self->cpfile("$ssl_conf/$_", "$conf/$_");
        }
        for (qw(certs keys crl)) {
            $self->symlink("$ssl_conf/$_", "$conf/$_");
        }
    }
}

sub find_in_inc {
    my($self, $dir) = @_;
    for my $path (@INC) {
        my $location = "$path/$dir";
        return $location if -d $location;
    }
    return "";
}

sub generate_httpd_conf {
    my $self = shift;
    my $vars = $self->{vars};

    #generated httpd.conf depends on these things to exist
    $self->generate_types_config;
    $self->generate_index_html;

    for (qw(t_logs t_conf)) {
        $self->gendir($self->{vars}->{$_});
    }

    if (my $extra_conf = $self->generate_extra_conf) {
        for my $file (@$extra_conf) {
            $self->postamble(Include => qq("$file"));
        }
    }

    $self->configure_proxy;

    my $conf_file = $vars->{t_conf_file};
    my $conf_file_in = join '.', $conf_file, 'in';

    my $in = $self->httpd_conf_template($conf_file_in);

    my $out = $self->genfile($conf_file, 1);

    $self->preamble_run($out);

    for my $name (qw(user group)) { #win32/cygwin do not support
        if ($vars->{$name}) {
            print $out "\u$name    $vars->{$name}\n";
        }
    }

    $self->replace_vars($in, $out);

    print $out "\n";

    $self->postamble_run($out);

    close $in;
    close $out or die "close $conf_file: $!";
}

sub need_reconfiguration {
    my $self = shift;
    my @reasons = ();
    my $vars = $self->{vars};

    # if httpd.conf is older than httpd executable
    push @reasons, 
        "$vars->{httpd} is newer than $vars->{t_conf_file}"
            if -e $vars->{httpd} && 
               -e $vars->{t_conf_file} &&
               -M $vars->{httpd} < -M $vars->{t_conf_file};

    # if .in files are newer than their derived versions
    if (my $extra_conf = $self->generate_extra_conf) {
        for my $file (@$extra_conf) {
            push @reasons, "$file.in is newer than $file"
                if -e $file && -M "$file.in" < -M $file;
        }
    }

    return @reasons;
}


#shortcuts

my %include_headers = (GET => 1, HEAD => 2);

sub http_raw_get {
    my($self, $url, $h) = @_;

    $url = "/$url" unless $url =~ m:^/:;

    my $ih = exists $include_headers{$h ||= 0} ?
      $include_headers{$h} : $h;

    require Apache::TestRequest;
    Apache::TestRequest::http_raw_get($self,
                                      $url, $ih);
}

sub error_log {
    my($self, $rel) = @_;
    my $file = catfile $self->{vars}->{t_logs}, 'error_log';
    my $rfile = abs2rel $file, $self->{vars}->{top_dir};
    return wantarray ? ($file, $rfile) :
      $rel ? $rfile : $file;
}

#utils

sub trace {
    my $self = shift;
    return unless $self->{verbose};
    print "@_\n";
}

#duplicating small bits of Apache::Build so we dont require it
sub which {
    foreach (map { catfile $_, $_[0] } File::Spec->path) {
	return $_ if -x;
    }
}

sub apxs {
    my($self, $q, $ok_fail) = @_;
    return unless $self->{APXS};
    my $val = qx($self->{APXS} -q $q 2>/dev/null);
    unless ($val) {
        if ($ok_fail) {
            return "";
        }
        else {
            warn "APXS ($self->{APXS}) query for $q failed\n";
        }
    }
    $val;
}

sub pop_dir {
    my $dir = shift;

    my @chunks = splitdir $dir;
    while (my $remove = shift) {
        pop @chunks if $chunks[-1] eq $remove;
    }

    catfile @chunks;
}

sub add_inc {
    my $self = shift;
    require lib;
    lib::->import(map "$self->{vars}->{top_dir}/$_",
                  qw(lib blib/lib blib/arch));
    #print join "\n", @INC, "";
}

#freeze/thaw so other processes can access config

sub thaw {
    my $class = shift;
    $class->new({thaw => 1, @_});
}

sub freeze {
    require Data::Dumper;
    local $Data::Dumper::Terse = 1;
    my $data = Data::Dumper::Dumper(shift);
    chomp $data;
    $data;
}

sub sync_vars {
    my $self = shift;

    return if $self->{save}; #this is not a cached config

    my $changed = 0;
    my $thaw = $self->thaw;
    my $tvars = $thaw->{vars};
    my $svars = $self->{vars};

    for my $key (@_) {
        for my $v ($tvars, $svars) {
            if (exists $v->{$key} and not defined $v->{$key}) {
                $v->{$key} = ''; #rid undef
            }
        }
        next if exists $tvars->{$key} and exists $svars->{$key} and
                       $tvars->{$key} eq $svars->{$key};
        $tvars->{$key} = $svars->{$key};
        $changed = 1;
    }

    return unless $changed;

    $thaw->{save} = 1;
    $thaw->save;
}

sub save {
    my($self) = @_;

    return unless $self->{save};

    my $name = 'apache_test_config';
    my $file = catfile $self->{vars}->{t_conf}, "$name.pm";
    my $fh = $self->genfile($file, 1);

    $self->trace("saving config data to $name.pm");

    (my $obj = $self->freeze) =~ s/^/    /;

    print $fh <<EOF;
package $name;

sub new {
$obj;
}

1;
EOF

    close $fh or die "failed to write $file: $!";
}

1;
__DATA__
ServerRoot   "@ServerRoot@"
DocumentRoot "@DocumentRoot@"

Listen     @Port@
Port       @Port@
ServerName @ServerName@

PidFile     @t_logs@/httpd.pid
ErrorLog    @t_logs@/error_log
LogLevel    debug
TransferLog @t_logs@/access_log

ServerAdmin @ServerAdmin@

#needed for http/1.1 testing
KeepAlive       On

HostnameLookups Off

<Directory />
    Options FollowSymLinks
    AllowOverride None
</Directory>

<IfModule @THREAD_MODULE@>
    StartServers         1
    MaxClients           @MaxClients@
    MinSpareThreads      @MaxClients@
    MaxSpareThreads      @MaxClients@
    ThreadsPerChild      @MaxClients@
    MaxRequestsPerChild  0
</IfModule>

<IfModule perchild.c>
    NumServers           1
    StartThreads         @MaxClients@
    MinSpareThreads      @MaxClients@
    MaxSpareThreads      @MaxClients@
    MaxThreadsPerChild   @MaxClients@
    MaxRequestsPerChild  0
</IfModule>

<IfModule prefork.c>
    StartServers         @MaxClients@
    MaxClients           @MaxClients@
    MaxRequestsPerChild  0
</IfModule>

<Location /server-info>
    SetHandler server-info
</Location>

<Location /server-status>
    SetHandler server-status
</Location>

#so we can test downloading some files of various size
Alias /getfiles-perl-pod          @PerlPod@

#and some big ones
Alias /getfiles-binary-httpd      @httpd@
Alias /getfiles-binary-perl       @perl@
