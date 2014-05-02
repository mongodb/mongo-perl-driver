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

package MongoDB::WriteSelector;

# ABSTRACT: MongoDB selector for write operations

use version;
our $VERSION = 'v0.703.5'; # TRIAL

use boolean;
use Moose;
use namespace::clean -except => 'meta';

with 'MongoDB::Role::_Selector';

has _upsert => (
    is => 'ro',
    isa => 'boolean',
    default => sub { boolean::false },
);

sub upsert {
    my ($self) = @_;
    unless ( @_ == 1 ) {
        confess "the upsert method takes no arguments";
    }
    return $self->new( %$self, _upsert => boolean::true );
}

sub update {
    push @_, "update";
    goto &_update;
}

sub update_one {
    push @_, "update_one";
    goto &_update;
}

sub replace_one {
    push @_, "replace_one";
    goto &_update;
}

sub _update {
    my $method = pop @_;
    my ($self, $doc) = @_;

    # XXX replace this with a proper argument check for acceptable selector types
    unless ( @_ == 2 && ref $doc eq 'HASH' ) {
        confess "argument to $method must be a single hash reference";
    }

    if ( $method eq 'replace_one' ) {
        if ( grep { substr($_,0,1) eq '$' } keys %$doc ) {
            confess "no $method document keys may be '\$' prefixed operators";
        }
    }
    else {
        if ( grep { substr($_,0,1) ne '$' } keys %$doc ) {
            confess "all $method document keys must be '\$' prefixed operators";
        }
    }

    my $update = {
        q => $self->query,
        u => $doc,
        multi => $method eq 'update' ? boolean::true : boolean::false,
        upsert => $self->_upsert,
    };

    $self->_enqueue_op( [ update => $update ] );

    return $self;
}

sub remove {
    my ($self) = @_;
    $self->_enqueue_op( [ delete => { q => $self->query, limit => 0 } ] );
}

sub remove_one {
    my ($self) = @_;
    $self->_enqueue_op( [ delete => { q => $self->query, limit => 1 } ] );
}

__PACKAGE__->meta->make_immutable;

1;