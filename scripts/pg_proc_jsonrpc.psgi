#!perl

use strict;
use warnings;

use DBI;
use DBD::Pg;
use DBIx::Connector;
use Time::HiRes;
use POSIX qw(strftime);
use File::Path qw(make_path);
use JSON;
use Plack::Request;
use Regexp::Common qw(net delimited);

my $extensive_logging_path = '/tmp/pg_proc_jsonrpc';
my $extensive_logging_filename;

require TrustlyApi;
require TrustlyApi::Mapper;
require TrustlyApi::DBConnection;

# DBIx::Connector allows us to safely reuse connections by making sure that we
# don't reuse DBI connections we inherited from our parent process after a
# fork().
my $dbconnector = DBIx::Connector->new("dbi:Pg:service=pg_proc_jsonrpc", '', '', {pg_enable_utf8 => 1, RaiseError => 0, PrintError => 0});
my $dbc = TrustlyApi::DBConnection->new($dbconnector);


my $app = sub {
    my $env = shift;
    my $method_call;
    my $function_call;

    my $invalid_request = [
        '400',
        [ 'Content-Type' => 'application/json; charset=utf-8' ],
        [ to_json({
            jsonrpc => '2.0',
            error => {
                code => -32600,
                message => 'Invalid Request.'
            },
            id => undef
        }, {pretty => 1}) ]
    ];

    my ($method, $params, $id, $version);
    if ($env->{REQUEST_METHOD} eq 'GET') {
        my $req = Plack::Request->new($env);
        $method = $req->path_info;
        $method =~ s{^.*/}{};
        $params = $req->query_parameters->mixed;

        $method_call =
            {
                method  => $method,
                params  => $params,
                id      => 1,
                is_v1_api_call => 0
            };

        # default to 1.1
        $version = 1.1;
    } elsif ($env->{REQUEST_METHOD} eq 'POST') {
        my $json_input;
        my $jsonrpc;
        $env->{'psgi.input'}->read($json_input, $env->{CONTENT_LENGTH});
        my $json_rpc_request = from_json($json_input);
        _log_request($json_input);


        $method_call =
            {
                method  => $json_rpc_request->{method},
                params  => $json_rpc_request->{params},
                id      => $json_rpc_request->{id}
            };

        if ($env->{REQUEST_URI} =~ '/+api/1') {
            $method_call->{is_v1_api_call} = 1
        }
        elsif ($env->{REQUEST_URI} =~ '/+api/Legacy') {
            $method_call->{is_v1_api_call} = 0;
        }
        else {
            print STDERR "unrecognized request uri \"".$env->{REQUEST_URI}."\"\n";
            return $invalid_request;
        }

        $version = $json_rpc_request->{version};
        $jsonrpc = $json_rpc_request->{jsonrpc};

        # must be version 2.0 if "jsonrpc" is defined
        if (defined $jsonrpc)
        {
            return $invalid_request if ($jsonrpc ne '2.0');
            return $invalid_request if (defined $version);
            $version = '2.0';
        }
        
        # assume 1.0 if "version" is not defined
        if (!defined $version)
        {
            $version = 1.0;
        }

        if (!($version eq '1.0' || $version eq '1.1' || $version eq '2.0'))
        {
            # unsupported version
            return $invalid_request;
        }
    } else {
        return $invalid_request;
    }

    my $result;

    my $error = undef;
    my $success;

    # A list of SQLSTATEs which, after failure, have a reasonably good chance
    # of succeeding if retried.  See
    # http://www.postgresql.org/docs/current/static/errcodes-appendix.html for
    # a list of error codes.
    my @retryable_sqlstates = (
                                "40001", # serialization failure
                                "40P01"  # deadlock
                              );
    $success = 0;
    eval
    {
        # Now map the API method call into a database function call
        my $host = _get_host($env);
        $function_call = TrustlyApi::Mapper::api_method_call_mapper($method_call, $dbc, $host);

        # loop until we hit an error we can't recover from
        my $delay = 0.1;
        while ($delay <= 9.0)
        {
            my $proname = $function_call->{proname};
            $result = $dbc->call_function($function_call);

            if (defined $result->{rows})
            {
                $success = 1;
                last;
            }

            # if there's no reason to assume that retrying would help, exit the loop
            last if (scalar grep { $_ eq $result->{state} } @retryable_sqlstates) == 0;

            # sleep for a while and then retry
            print STDERR "ERROR SQLSTATE $result->{state};  retrying in $delay seconds\n";
            Time::HiRes::sleep($delay);
            $delay = $delay * 3;
        }
    };

    # extract the appropriate error message if the function call didn't succeed
    if ($@) {
        $error = $@;
    }
    elsif (!$success) {
        $error = $result->{errstr};
    }

    my $response = { };

    if (defined $id) {
        $response->{id} = $id;
    }

    if ($version eq '1.1') {
        $response->{version} = $version;
    }
    elsif ($version eq '2.0') {
        $response->{jsonrpc} = $version;
    }

    if ($success) {
        $response->{result} = TrustlyApi::create_result_object($dbc, $method_call, $function_call, $result);
    } else {
        my $log_filename = $extensive_logging_filename // "";
        $response->{error} = TrustlyApi::create_error_object($dbc, $method_call, $function_call, $error, $log_filename);
    }

    my $json_response = to_json($response, {pretty => 1});
    _log_response($method_call, $json_response);

    # finished logging for this request
    _extensive_log_finish_request();

    return [
        '200',
        [ 'Content-Type' => 'application/json; charset=utf-8' ],
        [ $json_response ]
    ];
};

sub _get_extensive_logging_filename
{
    my ($merchant_id, $type) = @_;

    if ($type eq 'request')
    {
        my $date = strftime("%Y%m%d", localtime);
        my $time = strftime("%H%M%S.", localtime).(Time::HiRes::gettimeofday())[1];

        my $path = "$extensive_logging_path/$merchant_id/$date";
        make_path($path);
        $extensive_logging_filename = "$path/$time";
    }
    elsif (!defined $extensive_logging_filename)
    {
        # should only happen for GET requests
        return undef;
    }
    
    return "$extensive_logging_filename.$type";
}

sub _write_extensive_log
{
    my ($filename, $content) = @_;

    open(my $fh, ">", $filename) or die "could not open log file $filename: $!";
    print $fh $content or die "could not write to log file $filename: $!";
    close($fh);
}

sub _get_merchant_id_from_params
{
    my $params = shift;

    # first look into "data" in case this is an api_call()
    return $params->{data}->{Username} if (defined $params->{data} && defined $params->{data}->{Username});
    # then look for a "Username"
    return $params->{Username} if (defined $params->{Username});

    # can't figure out the username, give up
    return 'no_merchant_id';
}

# unset extensive_logging_filename (see _get_extensive_logging_filename)
sub _extensive_log_finish_request
{
    $extensive_logging_filename = undef;
}

sub _log_request
{
    return if !defined $extensive_logging_path;

    my $json_input = shift;

    my $request = JSON::from_json($json_input);
    my $params = $request->{params};

    my $merchant_id = _get_merchant_id_from_params($params);
    my $path = _get_extensive_logging_filename($merchant_id, 'request');

    # censor out the passwords
    $params->{Password} =~ s/./*/g if defined $params->{Password};
    $params->{Data}->{Password} =~ s/./*/g if defined $params->{Data}->{Password};
    my $censored_json = JSON::to_json($request);

    # and then log the request
    _write_extensive_log($path, $censored_json);
}

sub _log_response
{
    return if !defined $extensive_logging_path;

    my ($method_call, $json) = @_;

    my $path = _get_extensive_logging_filename(undef, 'response');

    # skip if no path is set
    return if (!defined $path);

    _write_extensive_log($path, $json);
}


# Return either REMOTE_ADDR, or for internal IP addresses (see _is_internal_ip),
# return the HTTP X-Forwarded-For header.
sub _get_host
{
    my $env = shift;

    my $remote_addr = $env->{REMOTE_ADDR};
    
    if (_is_internal_ip($remote_addr))
    {
        my $x_forwarded_for = $env->{HTTP_X_FORWARDED_FOR};
        return $x_forwarded_for if (defined($x_forwarded_for) && $x_forwarded_for =~ /($RE{net}{IPv4})$/);
        # if x-forwarded-for is not available, just return REMOTE_ADDR
    }

    return $remote_addr;
}

# Return 1 if the given argument is an internal IP, 0 otherwise
sub _is_internal_ip
{
    my $ip = shift;

    return 1 if $ip eq "127.0.0.1"; # localhost
    return 1 if $ip eq "83.140.44.183"; # www.gluefinance.com
    return 1 if $ip =~ m{^93\.158\.127\.\d+}; # www-vrt.gluefinance.com
    return 1 if $ip =~ m{^10\.1\.1\.\d+};

    return 0;
}


__END__

=head1 NAME

pg_proc_jsonrpc.psgi - PostgreSQL Stored Procedures JSON-RPC Daemon

=head1 SYNOPSIS

How to setup using C<Apache2>, C<mod_perl> and L<Plack::Handler::Apache2>.
Instructions for a clean installation of Ubuntu 12.04 LTS.

Install necessary packages

  sudo apt-get install cpanminus build-essential postgresql-9.1 libplack-perl libdbd-pg-perl libjson-perl libmodule-install-perl libtest-exception-perl libapache2-mod-perl2 apache2-mpm-prefork

Create a database and database user for our shell user

  sudo -u postgres createuser --no-superuser --no-createrole --createdb $USER
  sudo -u postgres createdb --owner=$USER $USER

Try to connect

  psql -c "SELECT 'Hello world'"
    ?column?   
  -------------
   Hello world
  (1 row)

Create database user for apache

  sudo -u postgres createuser --no-superuser --no-createrole --no-createdb www-data

Download and build DBIx::Pg::CallFunction

  cpanm --sudo DBIx::Pg::CallFunction

Download and build DBIx::Connector

  cpanm --sudo DBIx::Pg::Connector

Grant access to connect to our database

  psql -c "GRANT CONNECT ON DATABASE $USER TO \"www-data\""

Configure pg_service.conf

  # copy sample config
  sudo cp -n /usr/share/postgresql/9.1/pg_service.conf.sample /etc/postgresql-common/pg_service.conf

  echo "
  [pg_proc_jsonrpc]
  application_name=pg_proc_jsonrpc
  dbname=$USER
  " | sudo sh -c 'cat - >> /etc/postgresql-common/pg_service.conf'


Configure Apache

  # Add the lines below between <VirtualHost *:80> and </VirtualHost>
  # to your sites-enabled file, or to the default file if this
  # is a new installation.

  # /etc/apache2/sites-enabled/000-default
  <Location /postgres>
    SetHandler perl-script
    PerlResponseHandler Plack::Handler::Apache2
    PerlSetVar psgi_app /usr/local/bin/pg_proc_jsonrpc.psgi
  </Location>
  <Perl>
    use Plack::Handler::Apache2;
    Plack::Handler::Apache2->preload("/usr/local/bin/pg_proc_jsonrpc.psgi");
  </Perl>

Restart Apache

  sudo service apache2 restart

Done!

You can now access PostgreSQL Stored Procedures, e.g.
L<http://127.0.0.1/postgres/now> using any JSON-RPC client,
such as a web browser, some Perl program, or
any application capable of talking HTTP and JSON-RPC.

Let's try it with an example!

Connect to our database using psql and copy/paste the SQL commands
to create a simple schema with some Stored Procedures.

Note the C<SECURITY DEFINER> below. It means the functions will
be executed by the same rights as our C<$USER>, with full access
to our database C<$USER>. The C<www-data> user is only granted
C<EXECUTE> access to the functions, and cannot touch the tables
using C<SELECT>, C<UPDATE>, C<INSERT> or C<DELETE> SQL commands.
You can think of C<SECURITY DEFINER> as a sudo for SQL.

  psql
  
  -- Some tables:
  
  CREATE TABLE users (
  userid serial not null,
  username text not null,
  datestamp timestamptz not null default now(),
  PRIMARY KEY (userid),
  UNIQUE(username)
  );
  
  CREATE TABLE usercomments (
  usercommentid serial not null,
  userid integer not null,
  comment text not null,
  datestamp timestamptz not null default now(),
  PRIMARY KEY (usercommentid),
  FOREIGN KEY (userid) REFERENCES Users(userid)
  );
  
  -- By default, all users including www-data, will be able to execute any functions.
  -- Revoke all access on functions from public, which allows us to explicitly grant
  -- access only to those functions we wish to expose publicly.
  
  ALTER DEFAULT PRIVILEGES REVOKE ALL ON FUNCTIONS FROM PUBLIC;
  
  -- Function to make a new comment
  
  CREATE OR REPLACE FUNCTION new_user_comment(_username text, _comment text) RETURNS BIGINT AS $$
  DECLARE
  _userid integer;
  _usercommentid integer;
  BEGIN
  SELECT userid INTO _userid FROM users WHERE username = _username;
  IF NOT FOUND THEN
      INSERT INTO users (username) VALUES (_username) RETURNING userid INTO STRICT _userid;
  END IF;
  INSERT INTO usercomments (userid, comment) VALUES (_userid, _comment) RETURNING usercommentid INTO STRICT _usercommentid;
  RETURN _usercommentid;
  END;
  $$ LANGUAGE plpgsql SECURITY DEFINER;

  -- Function to get all comments by a user

  CREATE OR REPLACE FUNCTION get_user_comments(OUT usercommentid integer, OUT comment text, OUT datestamp timestamptz, _username text) RETURNS SETOF RECORD AS $$
  SELECT
      usercomments.usercommentid,
      usercomments.comment,
      usercomments.datestamp
  FROM usercomments JOIN users USING (userid) WHERE users.username = $1
  ORDER BY 1
  $$ LANGUAGE sql SECURITY DEFINER;

  -- Function to get all comments by all users

  CREATE OR REPLACE FUNCTION get_all_comments(OUT usercommentid integer, OUT username text, OUT comment text, OUT datestamp timestamptz) RETURNS SETOF RECORD AS $$
  SELECT
      usercomments.usercommentid,
      users.username,
      usercomments.comment,
      usercomments.datestamp
  FROM usercomments JOIN users USING (userid)
  ORDER BY 1
  $$ LANGUAGE sql SECURITY DEFINER;
  
  -- Grant EXECUTE on the functions to www-data
  
  GRANT EXECUTE ON FUNCTION new_user_comment(_username text, _comment text) TO "www-data";
  GRANT EXECUTE ON FUNCTION get_user_comments(OUT usercommentid integer, OUT comment text, OUT datestamp timestamptz, _username text) TO "www-data";
  GRANT EXECUTE ON FUNCTION get_all_comments(OUT usercommentid integer, OUT username text, OUT comment text, OUT datestamp timestamptz) TO "www-data";

The JSON-RPC service supports both GET and POST,
let's try GET as it is easiest to test using a web browser.
However, when developing for real ALWAYS use POST and
set Content-Type to application/json.


  L<http://127.0.0.1/postgres/new_user_comment?_username=joel&_comment=Accessing+PostgreSQL+from+a+browser+is+easy!>
  {
     "error" : null,
     "result" : "1"
  }
  
  L<http://127.0.0.1/postgres/new_user_comment?_username=lukas&_comment=I+must+agree!+Also+easy+from+JQuery!>
  {
     "error" : null,
     "result" : "2"
  }
  
  L<http://127.0.0.1/postgres/new_user_comment?_username=claes&_comment=Or+using+JSON::RPC::Simple>
  {
     "error" : null,
     "result" : "3"
  }
  
  L<http://127.0.0.1/postgres/get_all_comments>
  {
     "error" : null,
     "result" : [
        {
           "usercommentid" : 1,
           "comment" : "Accessing PostgreSQL from a browser is easy!",
           "datestamp" : "2012-06-03 01:20:25.653989+07",
           "username" : "joel"
        },
        {
           "usercommentid" : 2,
           "comment" : "I must agree! Also easy from JQuery!",
           "datestamp" : "2012-06-03 01:21:30.19081+07",
           "username" : "lukas"
        },
        {
           "usercommentid" : 3,
           "comment" : "Or using JSON::RPC::Simple",
           "datestamp" : "2012-06-03 01:22:09.149454+07",
           "username" : "claes"
        }
     ]
  }

=head1 DESCRIPTION

C<pg_proc_jsonrpc> is a JSON-RPC daemon to access PostgreSQL stored procedures.

The script implements the L<PSGI> standard and can be started using
the L<plackup> script, or by any webserver capable of handling PSGI files,
such as Apache using L<Plack::Handler::Apache2>.

As L<DBI> is not thread safe, you must not use threaded webservers,
such as C<apache2-mpm-worker>, use instead e.g. C<apache2-mpm-prefork>.

It only supports named parameters, JSON-RPC version 1.1 or 2.0.

L<DBIx::Pg::CallFunction> is used to map
method and params in the JSON-RPC call to the corresponding
PostgreSQL stored procedure.  DBIx::Connector is used to safely
maintain database connections across requests.

=head1 SEE ALSO

L<plackup> L<Plack::Runner> L<PSGI|PSGI> L<DBIx::Pg::CallFunction> L<DBIx::Connector>

=cut
