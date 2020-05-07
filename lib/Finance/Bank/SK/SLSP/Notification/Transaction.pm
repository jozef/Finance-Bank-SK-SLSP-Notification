package Finance::Bank::SK::SLSP::Notification::Transaction;

use warnings;
use strict;
use utf8;

our $VERSION = '0.04';

use Web::Scraper;
use DateTime::Format::Strptime;

my $george_strp = DateTime::Format::Strptime->new(
    on_error => 'undef',
    pattern   => '%d.%m.%Y %H:%M:%S',
    time_zone => 'local',
);

use base 'Class::Accessor::Fast';

__PACKAGE__->mk_accessors(qw{
    original_text
    created_dt
}, ordered_attributes());

sub new {
    my ($class, %params) = @_;
    my $self  = $class->SUPER::new({ %params });
    return $self;
}

sub from_html {
    my ($class, $html) = @_;

    my $slsp_proc = scraper {
        process '//table[@class="tl"]',
            'original_text' => 'TEXT',
            process '//table[@class="tl"]/tr/td[@class="i1"]', 'main' => scraper {
            process 'p.n1',                   'display_name' => 'TEXT';
            process 'p.acc',                  'account_to'   => 'TEXT';
            process 'p.d1',                   'datum'        => 'TEXT';
            process 'p.a1',                   'amount'       => 'TEXT';
            process '//p[count(./span) = 2]', 'details[]'    => scraper {
                process '//span[position() = 1]', 'key'   => 'TEXT';
                process '//span[position() = 2]', 'value' => 'TEXT';
            };
            process 'div.pd p.z1.s1 span.z1-s1', 'note[]' => 'TEXT';
        }
    };
    my $res = $slsp_proc->scrape(\$html);

    die 'parsing failed: ' . $html
        unless $res->{main};

    $res->{main}->{details} = {
        map {s/^\s+//; s/\s+$//; $_;}
        map {$_->{key} => $_->{value}} @{$res->{main}->{details}}
    };
    foreach my $key (keys %{$res->{main}}) {
        next if ref($res->{main}->{$key});
        $res->{main}->{$key} =~ s/^\s+//;
        $res->{main}->{$key} =~ s/\s+$//;
    }

    my $display_name  = $res->{main}->{display_name};
    my $account_to    = $res->{main}->{account_to};
    my $original_text = $res->{original_text};
    my $datetime      = $george_strp->parse_datetime($res->{main}->{datum});
    die 'can not parse datetime: ' . $res->{main}->{datum}
        unless $datetime;
    my ($amount, $cent_amount);
    if ($res->{main}->{amount} =~ /^(-?\d+),(\d\d) EUR$/) {
        $cent_amount = int($1 . $2);
        $amount      = "$1.$2";
    }
    else {
        die 'can not parse amount: ' . $res->{main}->{amount};
    }
    my ($account_number, $account_name) =
        split(/\s+/, $res->{main}->{details}->{"Proti\x{fa}\x{10d}et:"}, 2);
    my $description =
        join(' ', grep {length($_)} map {s/^\s+//; s/\s$//; $_;} @{$res->{main}->{note}});

    return $class->new(
        display_name   => $display_name,
        type           => ($cent_amount > 0 ? 'credit' : 'payment'),
        account_number => $account_number,
        account_name   => $account_name,
        amount         => $amount,
        cent_amount    => $cent_amount,
        description    => $description,
        date1          => $datetime->strftime('%d%m%y'),
        date2          => $datetime->strftime('%d%m%y'),
        created_dt     => $datetime,
        original_text  => $original_text,
        account_to     => $account_to,
    );
}

sub from_txt {
    my ($class, $txt) = @_;

    my @transactions;

    if ($txt =~ m/^(Rezervácia|Storno rezervacie) \(POS\)/) {
        return;
    }
    elsif ($txt =~ m/^((Výber|Platba) kartou|Nákup na internete|Storno výberu kartou \(ATM\))/) {
        my $negative = ($txt =~ m/^Storno / ? 1 : 0);
        my $transaction = {};
        $transaction->{original_text} = $txt;
        my @lines = map { s/\s+$//; $_; } split(/\n/, $txt);
        $transaction->{display_name} = $lines[0];
        die 'failed to parse: '.$lines[1]
            if ($lines[1] !~ m/^Ciastka: (\d+),(\d{2}) EUR/);
        $transaction->{amount} = $1+($2/100);
        $transaction->{cent_amount} = $1.$2;
        if ($negative) {
            $transaction->{amount}      = 0 - $transaction->{amount};
            $transaction->{cent_amount} = 0 - $transaction->{cent_amount};
        }
        $transaction->{type} = 'payment';
        die 'failed to parse: '.$lines[1]
            if ($lines[2] !~ m/^Karta: (.+)/);
        $transaction->{account_number} = 'atmcard-'.$1;
        $transaction->{account_name} = '';
        $transaction->{description} = '';
        for (my $i = 3; $i < @lines; $i++) {
            last if ($lines[$i] =~ m/^\s*$/);
            $transaction->{description} .= $lines[$i] . ', ';
        }
        $transaction->{description} =~ s/, $//;
        push(@transactions, $transaction);
    }
    else {
        my ($transactions, $our_account1, $our_account2, @rest) =
            split(/_{10,}/, $txt);
        die 'failed parsing 1' unless $transactions || $our_account1 || $our_account2;
        my $our_account = $our_account1.$our_account2;
        die 'failed parsing 2' unless @rest == 1 || $rest[0] eq '';

        { # get transactions
            my @trans_lines = split(/\r?\n/, $transactions);
            if ($trans_lines[0] =~ m/^(\s+)\d/) {
                my $prefix_whitespace = $1;
                @trans_lines = map {
                    length($_) >= length($prefix_whitespace)
                    ? substr($_, length($prefix_whitespace))
                    : ''
                } @trans_lines;
                my $current_transaction;
                foreach my $line (@trans_lines) {
                    if ($line =~ m/^(\d+)\s/) {
                        push(@transactions, $current_transaction)
                            if $current_transaction;
                        $current_transaction = { original_text => '' };
                    }
                    $current_transaction->{original_text} .= $line."\n";
                }
                push(@transactions, $current_transaction)
                    if $current_transaction;
            }
        }

        #parse transactions
        foreach my $transaction (@transactions) {
            my @lines = split(/\n/,$transaction->{original_text});

            my $info_line = shift(@lines);
            die 'failed parsing "'.$info_line.'"'
                unless $info_line =~ m/
                    ^\d+ \s
                    (.+?) \s+
                    (\d{6}) \s+
                    (\d{6}) \s+
                    (-?\d+\.\d{2}) $
                /xms;
            $transaction->{display_name} = $1;
            $transaction->{date1} = $2;
            $transaction->{date2} = $3;
            $transaction->{amount} = $4;
            $transaction->{cent_amount} = $transaction->{amount};
            $transaction->{cent_amount} =~ s/[.]//;
            $transaction->{cent_amount} += 0;
            $transaction->{type} = ($transaction->{amount} > 0 ? 'credit' : 'payment');

            $transaction->{account_number} = '';
            $transaction->{account_name}   = '';
            my $account_line = shift(@lines);
            if ($account_line =~ m/
                ^\s
                (?:(\w{2} \d [^\s]{5,40}) \s)?    # IBAN should be max 34 chars wide but it depends on country
                ([^\s] .+)?
                $
            /xms) {
                $transaction->{account_number} = $1;
                $transaction->{account_name}   = $2;
                $transaction->{account_name}   =~ s/\s+$//;
            }

            my $symbols_line = shift(@lines);
            die 'failed parsing "'.$symbols_line.'"'
                unless $symbols_line =~ m/
                    ^\s
                    VS:(\d*) \s
                    KS:(\d*) \s
                    SS:(\d*)
                    $
                /xms;
            $transaction->{vs} = $1 if length($1 // '');
            $transaction->{ks} = $2 if length($2 // '');
            $transaction->{ss} = $3 if length($3 // '');

            @lines =
                map { s/^\s+//;$_ }
                map { s/\s+$//;$_ }
                grep { $_ !~ m/^\s*$/ } @lines;
            $transaction->{description} = join("", @lines);
        }
    }

    @transactions = map { $class->new(%{$_}) } @transactions;
    return @transactions;

}

sub as_text {
    my ($self) = @_;
    my $text = '';
    foreach my $attr ($self->ordered_attributes) {
        $text .= $attr.': '.(defined($self->$attr) ? $self->$attr : '')."\n";
    }
    return $text;
}

sub as_data {
    my ($self) = @_;
    my %trans_data;
    foreach my $attr ($self->ordered_attributes) {
        $trans_data{$attr} = $self->$attr;
    }
    return \%trans_data;
}

sub ordered_attributes {
    return qw(
        account_to
        type
        display_name
        account_name
        account_number
        amount
        cent_amount
        date1
        date2
        vs
        ks
        ss
        description
    );
}

1;


__END__

=head1 NAME

Finance::Bank::SK::SLSP::Notification::Transaction - parse txt transaction

=head1 SYNOPSIS

    my $trans = Finance::Bank::SK::SLSP::Notification::Transaction->from_txt_file($str);
    say $trans->type;
    say $trans->account_number;
    say $trans->vs;
    say $trans->ks;
    say $trans->ss;

    say $trans->as_text;

=head1 DESCRIPTION

=head1 PROPERTIES

=head1 METHODS

=head2 new()

Object constructor.

=head1 AUTHOR

Jozef Kutej

=cut
