package Finance::Bank::SK::SLSP::Notification;

use warnings;
use strict;

our $VERSION = '0.03';

use Email::MIME;
use File::Temp qw(tempdir);
use Path::Class qw(file dir);
use Archive::Extract;
use File::Find::Rule;
use Encode qw(decode from_to);
use Email::Address;
use DateTime::Format::Mail;

use Finance::Bank::SK::SLSP::Notification::Transaction;

use base 'Class::Accessor::Fast';

__PACKAGE__->mk_accessors(qw{
    header_obj
    attached_files
    transactions
    created_dt
    _tmpdir
});

sub new {
    my ($class, %params) = @_;

    $params{attached_files} ||= [];
    $params{transactions} ||= [];
    my $self  = $class->SUPER::new({ %params });

    return $self;
}

sub email_name {
    my ($self) = @_;
    my ($from) = Email::Address->parse($self->header_obj->header('From'));
    return $from->name;
}

sub email_from {
    my ($self) = @_;
    my ($from) = Email::Address->parse($self->header_obj->header('From'));
    return $from->address;
}

sub from_html {
    my ($class, $html) = @_;

    my $transaction = Finance::Bank::SK::SLSP::Notification::Transaction->from_html($html);
    return unless $transaction;

    return $class->new(
        transactions => [$transaction],
        created_dt   => $transaction->created_dt,
    );
}

sub from_email {
    my ($class, $email) = @_;

    my $parsed = Email::MIME->new($email);

    my $default_dt =
        eval {DateTime::Format::Mail->parse_datetime($parsed->header_obj->header('Date'))};

    my $zip_att_count = 0;
    foreach my $part ($parsed->parts) {

        my $filename = $part->filename;
        next unless $filename;
        next unless $filename =~ m/\.zip$/;
        $zip_att_count++;
        my $body = $part->body;

        my $tmpdir = tempdir( CLEANUP => 1 );
        my $zip_file = file($tmpdir, $filename);
        $zip_file->spew($body);
        my $extract_dir = dir($tmpdir, 'extracted');
        $extract_dir->mkpath;

        my $ae = Archive::Extract->new( archive => $zip_file ) || die 'fail '.$!;
        $ae->extract( to => $extract_dir ) || die $ae->error;

        my @transactions;
        my @files =
            map { file($_) }
            File::Find::Rule
            ->file()
            ->name( '*' )
            ->in( $extract_dir );

        foreach my $file (@files) {
            next unless $file->basename =~ m/\.txt$/;
            my $content_raw = $file->slurp(iomode => '<:raw');
            from_to($content_raw, "windows-1250",'utf8',);
            $file->spew(iomode => '>:raw', $content_raw);
            my $content = decode('utf8', $content_raw);

            # process transactions
            if ($file->basename =~ m/^K\d+\.txt$/) {
                push(@transactions, Finance::Bank::SK::SLSP::Notification::Transaction->from_txt($content));
            }
        }

        if ($default_dt) {
            my $date_str = $default_dt->strftime('%d%m%y');
            foreach my $trans (@transactions) {
                $trans->{date1} //= $date_str;
                $trans->{date2} //= $date_str;
            }
        }

        return $class->new(
            header_obj          => $parsed->header_obj,
            attached_files      => \@files,
            transactions        => \@transactions,
            created_dt          => $default_dt,
            _tmpdir             => $tmpdir,
        )
    }

    unless ($zip_att_count) {
        return $class->new(
            header_obj   => $parsed->header_obj,
            transactions => [
                Finance::Bank::SK::SLSP::Notification::Transaction->from_body(
                    $parsed->header_obj->header('Subject'),
                    $parsed->body,
                )
            ],
            created_dt => $default_dt,
        );
    }

    return;
}

sub has_transactions {
    my ($self) = @_;
    return @{$self->transactions || []};
}

1;


__END__

=head1 NAME

Finance::Bank::SK::SLSP::Notification - parse email notifications

=head1 SYNOPSIS

    my $slsp = Finance::Bank::SK::SLSP::Notification->from_email($email_str);

    say $slsp->header_obj->header('From');
    say $slsp->attached_files;
    say $slsp->has_transactions;

    say $slsp->transactions->[0]->type;
    say $slsp->transactions->[0]->account_number;
    say $slsp->transactions->[0]->vs;
    say $slsp->transactions->[0]->ks;
    say $slsp->transactions->[0]->ss;

=head1 DESCRIPTION

=head1 PROPERTIES

=head1 METHODS

=head2 new()

Object constructor.

=head1 AUTHOR

Jozef Kutej

=cut
