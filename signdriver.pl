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

    home => [

        {
            route_tag => "6",
            stop_tag => "7025",
            runs => [qw(06_IB2 06_IB3)],
            walk_time => 4,
        },

        {
            route_tag => "71",
            stop_tag => "4944",
            runs => [qw(71_IB1)],
            walk_time => 8,
        },

        {
            route_tag => "N",
            stop_tag => "3911",
            runs => [qw(N__IBNUME N__IBEM6 N__IB3 N__IB1 N__IBJU4)],
            walk_time => 12,
        },

        {
            route_tag => "37",
            stop_tag => "6231",
            runs => [qw(37_OB1)],
            walk_time => 6,
        },

    ],

};

my $config = $configs->{$config_name};
die "No such config $config_name\n" unless $config;

my @remaining_string_file_names = 'a' .. 'z';
my $primary_string_file_name = shift @remaining_string_file_names;
my @ancillary_string_file_names = map { shift @remaining_string_file_names } 1 .. scalar(@$config);

my $serial_device = "/dev/ttyUSB0";
sysopen(my $fh, $serial_device, O_RDWR) || die "Can't open serial port: $!";
my $sign = Sign->new($fh);
$sign->sync_time();
$sign->configure_files(
    A => Sign::TextFile->new(
        mode('HOLD', 'TOP'),
        string($primary_string_file_name),
        (map { mode('ROLL_UP', 'BOTTOM'), string($_) } @ancillary_string_file_names),
        mode('ROLL_UP', 'BOTTOM'),
        string('z'),
        mode('ROLL_UP', 'BOTTOM'),
    ),
    a => Sign::StringFile->new(25),
    b => Sign::StringFile->new(25),
    c => Sign::StringFile->new(25),
    d => Sign::StringFile->new(25),
    e => Sign::StringFile->new(25),
    z => Sign::StringFile->new(128),
);
$sign->configure_text_file_run_sequence(qw(A));

my $ua = LWP::UserAgent->new();
$ua->agent("AlphaSignDriver/0.1");

# Make a different view of the config with the run tags as
# the keys, so we can find them from the prediction elements
# later.
my %runs = ();
foreach my $stop_config (@$config) {
    my $stop_code = $stop_config->{key};
    my $walk_time = $stop_config->{walk_time} || 0;
    my $runs = $stop_config->{runs};

    foreach my $run_code (@$runs) {
        $runs{$run_code} = {
            walk_time => $walk_time,
        };
    }
}
my $primary_route = $config->[0]{route_tag};

my @stop_codes = map { $_->{route_tag}."|null|".$_->{stop_tag} } @$config;
my $url_thing = join("&", map { "stops=".$_  } @stop_codes);

my $url = "http://webservices.nextbus.com/service/publicXMLFeed?command=predictionsForMultiStops&a=sf-muni&".$url_thing;
my $weather_url = "http://api.wunderground.com/auto/wui/geo/ForecastXML/index.xml?query=94107";
my $last_weather_time = 0;

while (1) {

    my $res = $ua->get($url);

    unless ($res->is_success) {
        warn "Failed to fetch predictions: ".$res->status_line."\n";
        sleep 10;
        next;
    }

    my $xml = $res->content;

    my $xp = XML::XPath->new(xml => $xml);

    my %predictions = ();

    foreach my $predictions_elem ($xp->findnodes("/body/predictions")) {

        my $route_tag = $predictions_elem->getAttribute("routeTag");

        foreach my $prediction_elem ($xp->findnodes("direction/prediction", $predictions_elem)) {
            my $minutes = $prediction_elem->getAttribute("minutes");
            my $run_tag = $prediction_elem->getAttribute("dirTag");
            my $run = $runs{$run_tag};
            next unless defined($run);

            my $walk_time = $run->{walk_time};

            my $leave_minutes = $minutes - $walk_time;
            next if $leave_minutes < 0;

            $predictions{$route_tag} ||= [];
            push @{$predictions{$route_tag}}, $minutes - $walk_time;
        }

    }

    use Data::Dumper;
    print Data::Dumper::Dumper(\%predictions);

    my $primary_str = format_predictions($primary_route, $predictions{$primary_route});
    $sign->set_string_file_text($primary_string_file_name => $primary_str);

    my $idx = 0;
    foreach my $route_config (@$config) {
        my $route_tag = $route_config->{route_tag};
        next if $route_tag eq $primary_route;

        my $file_name = $ancillary_string_file_names[$idx++];
        my $str = format_predictions($route_tag, $predictions{$route_tag});
        $sign->set_string_file_text($file_name => $str);
    }

    #@predictions = sort { $a->{minutes} <=> $b->{minutes} } @predictions;

    #my $idx = 0;
    #foreach my $string_name (@ancillary_string_file_names) {
    #    my $prediction = $predictions[$idx++];
    #    $sign->set_string_file_text($string_name => english_prediction($prediction));
    #}

    # Only poll the weather forecast every 30 minutes, since it doesn't change
    # as often as the bus predictions.
    my $weather_time = time();
    if (($weather_time - $last_weather_time) > 1800) {
        my $res = $ua->get($weather_url);

        unless ($res->is_success) {
            warn "Failed to fetch weather forecast: ".$res->status_line."\n";
            next;
        }

        my $xml = $res->content;

        my $xp = XML::XPath->new(xml => $xml);

        my ($forecast_elem) = $xp->findnodes("/forecast/simpleforecast/forecastday");

        my $conditions = $xp->findvalue('conditions', $forecast_elem);
        my $low_temp = $xp->findvalue('low/fahrenheit', $forecast_elem);
        my $high_temp = $xp->findvalue('high/fahrenheit', $forecast_elem);

        my $weather_string = "$conditions $low_temp-$high_temp";

        $sign->set_string_file_text('z' => $weather_string);

    }
    $last_weather_time = $weather_time;

    sleep 30;

}

sub english_prediction {
    my ($prediction) = @_;

    return $prediction ? $prediction : "now";
}

sub format_predictions {
    my ($route_tag, $predictions) = @_;

    $predictions ||= [];

    my $ret = $route_tag . ": ";

    my @predictions = sort { $a <=> $b } @$predictions;
    if (@predictions > 4) {
        @predictions = @predictions[0..3];
    }
    
    #my @predictions = scalar(@$predictions) > 4 ? @$predictions[0..3] : @$predictions;

    if (@predictions) {
        $ret .= join(', ', map { english_prediction($_) } @predictions);
    }
    else {
        $ret .= "no predictions";
    }

}
