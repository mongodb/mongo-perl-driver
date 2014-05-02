#
#  Copyright 2014 MongoDB, Inc.
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

use 5.008;
use strict;
use warnings;

package MongoDB::Error;
# ABSTRACT: MongoDB Driver Error classes

use version;
our $VERSION = 'v0.703.5'; # TRIAL

use Moose;
use namespace::clean -except => 'meta';

use overload
  q{""}    => sub { shift->message },
  fallback => 1;

=attr message

A text representation of the error

=cut

has message => (
    is      => 'ro',
    isa     => 'Str',
    default => 'unspecified error',
);

=method throw

    MongoDB::Error->throw("message");
    MongoDB::Error->throw(
        msg => "message",
        details => $data,
    );
    MongoDB::Error->throw( $error_object );

=cut

with 'Throwable';

around BUILDARGS => sub {
    my $orig  = shift;
    my $class = shift;
    if ( @_ == 1 && !ref $_[0] ) {
        return $class->$orig( message => $_[0] );
    }
    return $class->$orig(@_);
};

package MongoDB::ConnectionError;
use Moose;
use namespace::clean -except => 'meta';
extends("MongoDB::Error");

package MongoDB::DatabaseError;
use Moose;
use namespace::clean -except => 'meta';
extends("MongoDB::Error");

=attr details (DatabaseError only)

An optional object with about the error.  The nature will
vary by error subclass.

=cut

has details => (
    is       => 'ro',
    does     => 'MongoDB::Role::_LastError',
    required => 1,
);

package MongoDB::BulkWriteError;
use Moose;
use namespace::clean -except => 'meta';
extends("MongoDB::DatabaseError");

# Internal error class for signalling commands in excess of
# max BSON wire size
package MongoDB::_CommandSizeError;
use Moose;
use namespace::clean -except => 'meta';
extends("MongoDB::Error");

has size => (
    is      => 'ro',
    isa     => 'Int',
    required => 1,
);

1;

__END__

=head1 SYNOPSIS

    use MongoDB::Error;

    MongoDB::Error->throw("a generic error");

    MongoDB::DatabaseError->throw(
        message => $string,
        details => $hashref,
    );

=head1 DESCRIPTION

This class defines a heirarchy of exception objects.

=head1 EXCEPTION HIERARCHY

All classes inherit from C<MongoDB::Error>.

=head2 MongoDB::ConnectionError

Errors related to network connections.

=head2 MongoDB::DatabaseError

Errors related to database operations.

=head3 MongoDB::BulkWriteError

=cut

=cut

=cut

# vim: ts=4 sts=4 sw=4 et: