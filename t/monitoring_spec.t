#
#  Copyright 2018 - present MongoDB, Inc.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#

use strict;
use warnings;
use Test::More 0.96;
use JSON::MaybeXS qw( is_bool decode_json );
use Test::Deep;
use Path::Tiny;
use Try::Tiny;
use version;

use MongoDB;

use lib "t/lib";
use MongoDBTest qw/
    skip_unless_mongod
    build_client
    get_test_db
    server_version
    server_type
    get_feature_compat_version
/;

skip_unless_mongod();

#--------------------------------------------------------------------------#
# Event callback for testing -- just closures over an array
#--------------------------------------------------------------------------#

my @events;

sub clear_events { @events = () }
sub event_count { scalar @events }
sub event_cb { push @events, $_[0] }

#--------------------------------------------------------------------------#

my $conn           = build_client( monitoring_callback => \&event_cb );
my $testdb         = get_test_db($conn);
my $server_version = server_version($conn);
my $server_type    = server_type($conn);
my $feat_compat_ver = get_feature_compat_version($conn);
my $coll           = $testdb->get_collection('test_collection');

# defines which argument hash fields become positional arguments
my %method_args = (
    insert_one => [qw( document )],
    insert_many => [qw( documents )],
    delete_one => [qw( filter )],
    delete_many => [qw( filter )],
    update_one => [qw( filter update )],
    update_many => [qw( filter update )],
    find => [qw( filter )],
    count => [qw( filter )],
    bulk_write => [qw( requests )],
);

my $dir = path("t/data/command-monitoring");
my $iterator = $dir->iterator( { recurse => 1 } );
while ( my $path = $iterator->() ) {
    next unless -f $path && $path =~ /\.json$/;
    my $plan = eval { decode_json( $path->slurp_utf8 ) };
    if ($@) {
        die "Error decoding $path: $@";
    }

    my $name = $path->relative($dir)->basename(".json");

    subtest $name => sub {
        for my $test ( @{ $plan->{tests} } ) {
            subtest $test->{description} => sub {

                my $max_ver = $test->{ignore_if_server_version_greater_than};
                my $min_ver = $test->{ignore_if_server_version_less_than};

                plan skip_all => "Ignored for versions above $max_ver"
                    if defined $max_ver
                    and $server_version > version->parse("$max_ver");
                plan skip_all => "Ignored for versions below $min_ver"
                    if defined $min_ver
                    and $server_version < version->parse("$min_ver");

                $coll->drop;
                $coll->insert_many( $plan->{data} );
                clear_events();

                my $op   = $test->{operation};
                my $meth = $op->{name};
                $meth =~ s{([A-Z])}{_\L$1}g;
                my $test_meth = "test_$meth";
                my $res = test_dispatch(
                    $meth,
                    $op->{arguments},
                    $test->{expectations},
                );
            };
        }
    };
}

#--------------------------------------------------------------------------#
# generic tests
#--------------------------------------------------------------------------#

sub test_dispatch {
    my ($method, $args, $events) = @_;
    my @call_args = _adjust_arguments($method, $args);
    my $res = eval {
        my $res = $coll->$method(@call_args);
        $res->all
            if $method eq 'find';
        $res;
    };
    my $err = $@;
    diag "error from '$method': $err"
        if $err;
    check_event_expectations($method, _adjust_types($events));
}

sub _adjust_arguments {
    my ($method, $args) = @_;
    $args = _adjust_types($args);
    my @fields = @{ $method_args{$method} };
    my @field_values = map {
        my $val = delete $args->{$_};
        ($method eq 'bulk_write' and $_ eq 'requests')
            ? _adjust_bulk_write_requests($val)
            : $val;
    } @fields;
    return(
        (grep { defined } @field_values),
        scalar(keys %$args) ? $args : (),
    );
}

sub _adjust_types {
    my ($value) = @_;
    if (ref $value eq 'HASH') {
        if (scalar(keys %$value) == 1) {
            my ($name, $value) = %$value;
            if ($name eq '$numberLong') {
                return 0+$value;
            }
        }
        return +{map {
            my $key = $_;
            ($key, _adjust_types($value->{$key}));
        } keys %$value};
    }
    elsif (ref $value eq 'ARRAY') {
        return [map { _adjust_types($_) } @$value];
    }
    else {
        return $value;
    }
}

sub _adjust_bulk_write_requests {
    my ($requests) = @_;
    return [map {
        my ($name, $args) = %$_;
        $name =~ s{([A-Z])}{_\L$1}g;
        +{ $name => [_adjust_arguments($name, $args)] };
    } @$requests];
}

sub check_command_started_event {
    my ($exp, $event) = @_;
    check_event($exp, $event);
}

sub check_command_succeeded_event {
    my ($exp, $event) = @_;
    check_event($exp, $event);
}

sub check_command_failed_event {
    my ($exp, $event) = @_;
    check_event($exp, $event);
}

sub _verify_is_positive_num {
    my $value = shift;
    return(0, "error code is not defined")
        unless defined $value;
    return(0, "error code is not positive")
        unless $value > 1;
    return 1;
}

sub _verify_is_nonempty_str {
    my $value = shift;
    return(0, "error message is not defined")
        unless defined $value;
    return(0, "error message is empty")
        unless length $value;
    return 1;
}

sub check_database_name_field {
    my ($exp_name, $event) = @_;
    ok defined($event->{databaseName}), "database_name defined";
    ok length($event->{databaseName}), "database_name non-empty";
}

sub check_command_name_field {
    my ($exp_name, $event) = @_;
    is $event->{commandName}, $exp_name, "command name";
}

sub check_reply_field {
    my ($exp_reply, $event) = @_;
    my $event_reply = $event->{reply};
    if (exists $exp_reply->{cursor}) {
        if (exists $exp_reply->{cursor}{id}) {
            $exp_reply->{cursor}{id} = code(\&_verify_is_positive_num)
                if $exp_reply->{cursor}{id} eq '42';
        }
    }
    if (exists $exp_reply->{writeErrors}) {
        for my $error (@{ $exp_reply->{writeErrors} }) {
            if (exists $error->{code} and $error->{code} eq 42) {
                $error->{code} = code(\&_verify_is_positive_num);
            }
            if (exists $error->{errmsg} and $error->{errmsg} eq '') {
                $error->{errmsg} = code(\&_verify_is_nonempty_str);
            }
        }
    }
    for my $exp_key (sort keys %$exp_reply) {
        cmp_deeply
            $event_reply->{$exp_key},
            prepare_data_spec($exp_reply->{$exp_key}),
            "reply field $exp_key";
    }
}

sub check_command_field {
    my ($exp_command, $event) = @_;

    # ordered defaults to true
    delete $exp_command->{ordered};

    my $event_command = $event->{command};
    if (exists $exp_command->{getMore}) {
        $exp_command->{getMore} = code(\&_verify_is_positive_num)
            if $exp_command->{getMore} eq '42';
    }
    for my $exp_key (sort keys %$exp_command) {
        cmp_deeply
            $event_command->{$exp_key},
            prepare_data_spec($exp_command->{$exp_key}),
            "command field $exp_key";
    }
}

sub prepare_data_spec {
    my ($spec) = @_;
    if (not ref $spec) {
        if ($spec eq 'test') {
            return any(qw( test test_collection ));
        }
        if ($spec eq 'test-unacknowledged-bulk-write') {
            return code(\&_verify_is_nonempty_str);
        }
        if ($spec eq 'command-monitoring-tests.test') {
            return code(\&_verify_is_nonempty_str);
        }
        return $spec;
    }
    elsif (is_bool $spec) {
        my $specced = $spec ? 1 : 0;
        return code(sub {
            my $value = shift;
            return(0, 'expected a true boolean value')
                if $specced and not $value;
            return(0, 'expected a false boolean value')
                if $value and not $specced;
            return 1;
        });
    }
    elsif (ref $spec eq 'ARRAY') {
        return [map {
            prepare_data_spec($_)
        } @$spec];
    }
    elsif (ref $spec eq 'HASH') {
        return +{map {
            ($_, prepare_data_spec($spec->{$_}))
        } keys %$spec};
    }
    else {
        return $spec;
    }
}

sub check_event_expectations {
    my ($method, $expected) = @_;
    my @got = @events;

    for my $exp ( @$expected ) {
        my ($exp_type, $exp_spec) = %$exp;
        subtest $exp_type => sub {
            ok(scalar(@got), 'event available')
                or return;
            my $event = shift @got;
            is($event->{type}.'_event', $exp_type, "is a $exp_type")
                or return;
            my $event_tester = "check_$exp_type";
            main->can($event_tester)->($exp_spec, $event);
        };
    }

    is scalar(@got), 0, 'no outstanding events';
}

sub check_event {
    my ($exp, $event) = @_;
    for my $key (sort keys %$exp) {
        my $check = "check_${key}_field";
        main->can($check)->($exp->{$key}, $event);
    }
}

done_testing;