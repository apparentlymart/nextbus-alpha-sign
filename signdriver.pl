#!/usr/bin/perl

use strict;
use warnings;
use LWP::UserAgent;
use XML::XPath;
use Fcntl;
use Sign;
use Sign::TextFile;
use Sign::StringFile;
use Sign::MessageUtil qw(mode string);

my $serial_device = "/dev/ttyUSB0";
sysopen(my $fh, $serial_device, O_RDWR) || die "Can't open serial port: $!";
my $sign = Sign->new($fh);
$sign->sync_time();
$sign->configure_files(
    A => Sign::TextFile->new(
        mode('HOLD', 'TOP'),
        string("a"), "  ", string("b"),
        (map { mode('ROLL_UP', 'BOTTOM'), string($_) } qw(c d e)),
        mode('ROLL_UP', 'BOTTOM'),
    ),
    B => Sign::TextFile->new(
        " " x 250,
    ),
    a => Sign::StringFile->new(15),
    b => Sign::StringFile->new(15),
    c => Sign::StringFile->new(15),
    d => Sign::StringFile->new(15),
    e => Sign::StringFile->new(15),
    z => Sign::StringFile->new(128),
);
$sign->configure_text_file_run_sequence(qw(A));

my $ua = LWP::UserAgent->new();
$ua->agent("AlphaSignDriver/0.1");

my $config_name = shift or die "Usage: signdriver.pl <configname>\n";

my $configs = {

    office => {

        "47|null|3163" => {
            runs => [qw(47_IB)],
            walk_time => 10,
        },
        "N+OWL|null|3164" => {
            runs => [qw(N__OWLOB2 N__OWLOB1)],
            walk_time => 10,
        },
        "N|null|5240" => {
            runs => [qw(N__OB2 N__OB3 N__OB1 N__OB4TJU)],
            walk_time => 15,
        },
        "KT|null|7166" => {
            runs => [qw(KT_OBMEMT KT__OBWP2 KT__OBWP3 KT__OB1 KT__OBWP1 KT_OBEMNS KT__OBEMB KT_OBMME)],
            walk_time => 18,
        },

    },

    oldhome => {

        "6|null|4942" => {
            runs => [qw(06_IB2 06_IB3)],
            walk_time => 2,
        },

        "71|null|4942" => {
            runs => [qw(71_IB1)],
            walk_time => 2,
        },

        "F|null|5668" => {
            runs => [qw(F__IBCTRO F__IBVN F__IBCHUR)],
            walk_time => 15,
        },

    },

    home => {

        "6|null|7025" => {
            runs => [qw(06_IB2 06_IB3)],
            walk_time => 4,
        },

        "71|null|4944" => {
            runs => [qw(71_IB1)],
            walk_time => 8,
        },

        "N|null|3911" => {
            runs => [qw(N__IBNUME N__IBEM6 N__IB3 N__IB1 N__IBJU4)],
            walk_time => 12,
        },

    },

};

my $config = $configs->{$config_name};
die "No such config $config_name\n" unless $config;

# Make a different view of the config with the run tags as
# the keys, so we can find them from the prediction elements
# later.
my %runs = ();
foreach my $stop_code (keys %$config) {
    my $stop_config = $config->{$stop_code};
    my $walk_time = $stop_config->{walk_time} || 0;
    my $runs = $stop_config->{runs};

    foreach my $run_code (@$runs) {
        $runs{$run_code} = {
            walk_time => $walk_time,
        };
    }
}

my @stop_codes = keys %$config;
my $url_thing = join("&", map { "stops=".$_  } @stop_codes);

my $url = "http://webservices.nextbus.com/service/publicXMLFeed?command=predictionsForMultiStops&a=sf-muni&".$url_thing;

my $last_message_string = "";

while (1) {

    my $res = $ua->get($url);

    unless ($res->is_success) {
        warn "Failed to fetch predictions: ".$res->status_line."\n";
        sleep 10;
        next;
    }

    my $xml = $res->content;

    my $xp = XML::XPath->new(xml => $xml);

    my %messages = ();
    my @predictions = ();

    foreach my $predictions_elem ($xp->findnodes("/body/predictions")) {

        my $route_tag = $predictions_elem->getAttribute("routeTag");

        foreach my $prediction_elem ($xp->findnodes("direction/prediction", $predictions_elem)) {
            my $minutes = $prediction_elem->getAttribute("minutes");
            my $run_tag = $prediction_elem->getAttribute("dirTag");
            my $run = $runs{$run_tag};
            next unless defined($run);

            my $walk_time = $run->{walk_time};

            my $leave_minutes = $minutes - $walk_time;
            next if $leave_minutes < 1;

            push @predictions, {
                route => $route_tag,
                minutes => $minutes - $walk_time,
            };
        }

        foreach my $message_elem ($xp->findnodes("message", $predictions_elem)) {
            my $message = $message_elem->getAttribute("text");
            $message =~ s/\s+/ /g;
            $messages{$message} = 1;
        }

    }

    my @messages = keys %messages;
    @predictions = sort { $a->{minutes} <=> $b->{minutes} } @predictions;

    my $idx = 0;
    foreach my $string_name (qw(a b c d e)) {
        my $prediction = $predictions[$idx++];
        $sign->set_string_file_text($string_name => english_prediction($prediction));
    }

    my $message_string = "";
    if (@messages) {
        $message_string = mode('ROTATE', 'BOTTOM').join("\cM", @messages);
    }

    if ($message_string ne $last_message_string) {
        $sign->set_text_file_text(B => $message_string);
        $sign->configure_text_file_run_sequence("A", ($message_string ? ("B") : ()));
    }
    $last_message_string = $message_string;


    sleep 30;

}

sub english_prediction {
    my ($prediction) = @_;

    return join("", $prediction->{route}, ": ", $prediction->{minutes}, "min");
}

