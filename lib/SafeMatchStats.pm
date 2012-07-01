package SafeMatchStats;

use Moo;
use v5.12;
use utf8;
use feature qw( unicode_strings );

use Try::Tiny;
use Capture::Tiny qw( capture );
use Safe;
use Carp;

our $VERSION = 0.01;

has regex         => ( is => 'ro', required => 1 ); # User input (constructor).
has modifiers     => ( is => 'ro'                ); # User input (constructor).
has regexp_str    => ( is => 'ro', lazy => 1, builder => \&_gen_re_string );
has regexp_obj    => ( is => 'ro', lazy => 1, builder => \&_safe_qr       );
has target        => ( is => 'rw', lazy => 1, default => sub { q{} } );
has _capture_dump => ( is => 'rw' );
has matched       => ( is => 'rw', default => sub{ undef } );
has debug_info    => ( is => 'ro', lazy => 1, default => \&_debug_info );

# Captures
my @attribs = qw/   prematch    match       postmatch   carat_n     digits  
                    array_minus array_plus  hash_minus  hash_plus           /;

foreach my $attrib ( @attribs  ) {
    has $attrib => ( 
        is      => 'ro', lazy    => 1, 
        builder => sub{ 
            return $_[0]->matched ? $_[0]->_capture_dump->{$attrib} : undef;
        }
    );
}

around BUILDARGS => sub {
    my ( $orig, $class, @args ) = @_;
    return $class->$orig( @args )
        unless @args == 1 && ! ref $args[0] eq 'HASH';
    return $class->$orig( regex => $_[0] );
};

sub do_match {
    my ( $self, $target ) = @_;
    $self->target( $target // $self->target );
    return scalar $self->_safe_match_gather;
}

sub _gen_re_string {
    my $self = shift;
    my $re_str = $self->_sanitize_re_string(     $self->regex     );
    my $mod_str = $self->_sanitize_re_modifiers( $self->modifiers );
    return "(?$mod_str:$re_str)";
}

sub _sanitize_re_string {
    my ( $self, $re_string ) = @_;
    no warnings 'qw';
    my @bad_varnames = qw%    \$\^\w    \@ENV    \$ENV
      \$[0()<>#!+-]    \$\{[\w()<>+^-]}    \@\{\w+}     %;
    $re_string =~ s/(?<!\\)($_)/\\$1/g foreach @bad_varnames;
    return $re_string;
}

sub _sanitize_re_modifiers {
    my ( $self, $modifiers ) = @_;
    return '' if !defined $modifiers;
    $modifiers =~ tr/msixadlu^-//cd;
    my @modifiers = split //, $modifiers;
    my %seen;
    return join '', grep { !$seen{$_}++ } @modifiers;
}

sub _safe_qr {
    my $self = shift;
    my $compartment = Safe->new;
    ${ $compartment->varglob('regexp') } = $self->regexp_str;
    my $re_obj =
      $compartment->reval('my $safe_reg = qr/$regexp/;');
    return if $@;    # Return "undef" if 'reval' caught an exception.
    return $re_obj;  # Otherwise return a regexp object.
}

sub _safe_match_gather {
    my $self = shift;
    my $target = $self->target;
    my $re_obj = $self->regexp_obj;
    $self->matched(0);
    try {
        alarm(2);
        $self->matched(1) if $target =~ m/$re_obj/;
        alarm(0);
        if( $self->matched ) {
            $self->match_dump( {
                digits    => 
                    [ map { substr $target, $-[$_], $+[$_] - $-[$_] } 0 .. $#- ],
                hash_plus => {%+},
                hash_minus => {%-},
                prematch   => ${^PREMATCH},
                match      => ${^MATCH},
                postmatch  => ${^POSTMATCH},
                carat_n    => $^N,
                array_minus => [ @- ],
                array_plus  => [ @+ ],
            } );
        }
    }
    catch {
        $self->matched(undef);
        my $message = _remove_diag_linenums( $_ );
        warn "Match threw an exception: $message";
    };
    return $self->matched;
}

sub _debug_info {
    my $self = shift;
    my $rv;
    my( undef, $stderr, undef ) = capture { 
        try {
            alarm(2);
            use re q/debug/;
            my $regex = $self->regexp_str;
            $rv = $self->target =~ m/$regex/;
            alarm(0);
        }
        catch {
            print STDERR "Exception thrown during debug: ", 
                         _remove_diag_linenums($_), "\n";
        };
        $rv;
    };
    return $stderr;
}

sub _remove_diag_linenums {
    my $message = shift;
    $message =~ s/\sat\s[\w.]+\sline\s\d+\.$/./;
    return $message;
}

1;
