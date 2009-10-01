#!/usr/bin/perl -w
#
# Authors: Javier Urúen Val <juruen@ebox-technologies.com>
#          Jesús García Sáez <jgarcia@warp.es>
#          José A. Calvo Fernández <jacalvo@ebox-technologies.com>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License, version 2, as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
# ----------------------------------------------------------------------------
# Install:
#   $ sudo aptitude install libgtk2-trayicon-perl libcrypt-ssleay-perl \
#     libwww-mechanize-perl libdatetime-perl
# ----------------------------------------------------------------------------
use FindBin;

# v Configurable options ------------------------------------------------------
my $COMPANY = "Warp";

$ENV{HTTPS_PKCS12_FILE}     = '/home/blaxter/.ssl/foo.p12';
$ENV{HTTPS_PKCS12_PASSWORD} = '';

# Enter your name here as it appears on users list
my $NAME = 'Jesús García Sáez';

my $auto_punch_in  = 0; # punch in on start?
my $auto_punch_out = 0; # punch out on pc shutdown?

my $host      = 'lisa.warp.es';
my $base_url  = "https://$host";

# Authenticate options
my $user      = 'jgarcia';
my $pass      = 'jgarcia';
# if your tt-* webapp is able to auth only with the certificate, put 1
my $authenticate_only_with_the_cert = 0;

# Variables de diseño y tal. colorcitos y tiempos :P
my $background_popup  = '#E9F5D5';
my $background_joins  = '#00FF00';
my $background_leaves = '#FF0000';

my $popup_delay_in_seconds = 3;
my $wait_time_in_seconds   = 30;
my $animation_delay        = 0.003;

my $ICON_FILE     = "$FindBin::Bin/punch_in.png";
my $ICON_OUT_FILE = "$FindBin::Bin/punch_out.png";

# ^ Configurable options ------------------------------------------------------

use WWW::Mechanize;

use DateTime;
use DateTime::Duration;

use Gtk2("init");
use Gtk2::TrayIcon;

use warnings;
use strict;
use encoding 'utf8';

# -----------------------------------------------------------------------------

my $silent = 1;    # no console output?

my $am_i_punched       = 0;    # shows if I am punched in
my $old_punched_status = 0;

my $punch_in_time;
my $daily_time;
my $weekly_time;

my %currentPeople;             # here we have the people working @ HQ
my $mech = WWW::Mechanize->new();    # for dealing with the website
$mech->add_header( 'Accept-Charset' => 'utf-8' );

# icons
my $in_icon;
my $out_icon;

# Gtk stuff
my $menu;
my $info_popup;                      # the popup onmouseover
my $notify_popup;                    # the popup when something happens
my $trayicon_box
  ;    # The "real" trayicon, here we have the icon who receives the events

my $hq_status_label;    # Label inside the popup onmouseover

my ( $old_x, $old_y );  # for position the $info_popup more quickly
my $disable_monitors_check = 0;    # from checkGmail

my $icon;
my $tray;
# -----------------------------------------------------------------------------
sub main {
    $in_icon  = load_icon_data($ICON_FILE);
    $out_icon = load_icon_data($ICON_OUT_FILE);

    build_popup_onmouseover();
    build_menu();

    # make the tayicon bottom-up style, fuck GUIs
    my $tray_hbox = Gtk2::HBox->new( 0, 0 );
    $tray_hbox->set_border_width(4);
    $icon = Gtk2::Image->new_from_pixbuf($in_icon);
    $tray_hbox->pack_start( $icon, 0, 0, 0 );

    $trayicon_box = Gtk2::EventBox->new;
    $trayicon_box->add($tray_hbox);
    $trayicon_box->signal_connect( 'enter_notify_event',
        sub { show_notify(); }
    );
    $trayicon_box->signal_connect( 'leave_notify_event',
        sub { $info_popup->hide; }
    );
    $trayicon_box->signal_connect( 'button_press_event',
        \&handle_button_press
    );

    $tray = Gtk2::TrayIcon->new("Check HQ");
    $tray->add($trayicon_box);
    $tray->show_all;

    login();
    if ( $auto_punch_in ) {
        punch_in();
    }
    else {
        change_state(0);
    }
    check();
    Glib::Timeout->add( $wait_time_in_seconds * 1000, sub { check(); } );
    Gtk2->main;
    exit 0;
}

sub change_state {
    my ( $working ) = @_;

    change_icon( $working );
    if ( $working ) {
        $punch_in_time = DateTime->now();
    }
    else {
        $punch_in_time = undef;
    }
    &my_hours;
}

sub change_icon {
    my ( $working ) = @_;

    my $pixbuf = $working ? $in_icon : $out_icon;
    $icon->set_from_pixbuf($pixbuf);
    $tray->window()
         ->invalidate_rect( new Gtk2::Gdk::Rectangle( 0, 0, 32, 32 ), 1 );
}

$SIG{TERM} = sub {
    print "SIG TERM...\n" unless $silent;
    punch_out() if $auto_punch_out;
    print "punch out done\n" unless $silent;
    end_program();

};

sub end_program {
    Gtk2->main_quit;
}

sub login {
    if ( $authenticate_only_with_the_cert ) {
        $mech->get( $base_url . '/login/ssl' );
    }
    else {
        $mech->get( $base_url . '/login/login' );

        $mech->submit_form(
            form_number => 1,
            fields      => {
                'user[name]'      => $user,
                'user[prepasswd]' => $pass
            }
        );
    }
}

sub punch_out {
    $mech->get( $base_url . '/timetracking/punch/punch_out' );
    change_state(0);
}

sub punch_in {
    $mech->get( $base_url . '/timetracking/punch/punch_in' );
    change_state(1);
}

sub whois_at_hq {
    # koke's idea, the server will be thankful
    $mech->add_header( 'X-Requested-With' => 'XMLHttpRequest' );
    $mech->get( $base_url . '/timetracking/hq' );

    my %people;
    my $response = $mech->content();

    for my $line ( split( '\n', $response ) ) {
        my ($name) = $line =~ m:<li>(.*)</li>:;
        $people{$name} = 1 if ( defined($name) );
    }

    return %people;
}

sub my_hours {
    $mech->add_header( 'X-Requested-With' => 'XMLHttpRequest' );
    $mech->get( $base_url . '/timetracking/punch' );

    my $found    = 0;
    my $response = $mech->content();
    for my $line ( split( '\n', $response ) ) {
        my ($info) = $line =~ m:<li>(Horas de.*)</li>:;
        if ($info) {
            my ( $h, $m ) = $info =~ m/(\d+):(\d+)/;
            my $time = DateTime::Duration->new( hours => $h, minutes => $m );
            if ( $found eq 0 ) {
                $daily_time = $time;
            }
            else {
                $weekly_time = $time;
            }
            $found++;
        }
        last if ( $found eq 2 );
    }
}

sub build_msg {
    my ( $join, $leave ) = @_;

    my @join  = @{$join};
    my @leave = @{$leave};

    if (@join) {
        my $msg;
        if ( @join == 1 ) {
            $msg = "<b>$join[0]</b> joins the party at $COMPANY HQ";
        }
        else {
            $msg = "The following people are already at <u>$COMPANY HQ</u>:\n\n";
            for my $name (@join) {
                $msg .= "\t<b>$name</b>\n";
            }
        }
        &popup( $msg, $background_joins );
    }

    if (@leave) {
        my $msg;
        if ( @leave == 1 ) {
            $msg = "<b>$leave[0]</b> leaves the party at $COMPANY HQ";
        }
        else {
            $msg = "The following people leave the party at $COMPANY HQ:\n\n";
            for my $name (@leave) {
                $msg .= "\t$name\n";
            }
        }
        if (@join) {
            Glib::Timeout->add(
                $popup_delay_in_seconds * 1000 * 2,
                sub {
                    popup( $msg, $background_leaves );
                }
            );
        }
        else {
            &popup( $msg, $background_leaves );
        }
    }
}

sub build_menu {
    $menu = Gtk2::Menu->new;

    my $menu_punch_in = Gtk2::ImageMenuItem->new('Punch in');
    $menu_punch_in->set_image(
        Gtk2::Image->new_from_stock( 'gtk-ok', 'menu' ) );
    $menu_punch_in->signal_connect(
        'activate',
        sub {
            punch_in();
        }
    );

    my $menu_punch_out = Gtk2::ImageMenuItem->new('Punch out');
    $menu_punch_out->set_image(
        Gtk2::Image->new_from_stock( 'gtk-cancel', 'menu' ) );
    $menu_punch_out->signal_connect(
        'activate',
        sub {
            punch_out();
        }
    );

    my $menu_quit = Gtk2::ImageMenuItem->new_from_stock('gtk-quit');
    $menu_quit->signal_connect( 'activate', sub { end_program(); } );

    $menu->append($menu_punch_in);
    $menu->append($menu_punch_out);
    $menu->append( Gtk2::SeparatorMenuItem->new );
    $menu->append($menu_quit);

    $menu->show_all;
}

sub handle_button_press {
    my ( $widget, $event ) = @_;

    my $x = $event->x_root - $event->x;
    my $y = $event->y_root - $event->y;

    if ( $event->button != 1 ) {
        $menu->popup( undef, undef, sub { return position_menu( $x, $y ) },
            0, $event->button, $event->time );
    }
}

sub position_menu {
    # Modified from yarrsr
    my ( $x, $y ) = @_;

    my $monitor = $menu->get_screen->get_monitor_at_point( $x, $y );
    my $rect = $menu->get_screen->get_monitor_geometry($monitor);

    my $space_above = $y - $rect->y;
    my $space_below = $rect->y + $rect->height - $y;

    my $requisition = $menu->size_request();

    if (   $requisition->height <= $space_above
        || $requisition->height <= $space_below )
    {
        if ( $requisition->height <= $space_below ) {
            $y = $y + $trayicon_box->allocation->height;
        }
        else {
            $y = $y - $requisition->height;
        }
    }
    elsif ($requisition->height > $space_below
        && $requisition->height > $space_above )
    {
        if ( $space_below >= $space_above ) {
            $y = $rect->y + $rect->height - $requisition->height;
        }
        else {
            $y = $rect->y;
        }
    }
    else {
        $y = $rect->y;
    }

    return ( $x, $y, 1 );
}

# checkGmail stuff :P
# returns monitor, geometry, width, height of the screen
sub get_screen {
    my ( $boxx, $boxy ) = @_;

    # get screen resolution
    my $monitor =
      $trayicon_box->get_screen->get_monitor_at_point( $boxx, $boxy );
    my $rect   = $trayicon_box->get_screen->get_monitor_geometry($monitor);
    my $height = $rect->height;

    # support multiple monitors (thanks to Philip Jagielski for this simple solution!)
    my $width;
    unless ($disable_monitors_check) {
        for my $i ( 0 .. $monitor ) {
            $width +=
              $trayicon_box->get_screen->get_monitor_geometry($i)->width;
        }
    }
    else {
        $width =
          $trayicon_box->get_screen->get_monitor_geometry($monitor)->width;
    }

    return ( $monitor, $rect, $width, $height );
}

# In checkGmail the notify window is created every time. Because (i think) the
# contents will be so many and so much complex that this little crap.
# Here we only needs a simple text. Build in the begginning and after that just
# set the text we wanna show up.
sub build_popup_onmouseover {
    my ($status) = @_;
    $info_popup = Gtk2::Window->new('popup');

    my $notifybox_b = Gtk2::EventBox->new;
    $notifybox_b->modify_bg( 'normal', Gtk2::Gdk::Color->new( 0, 0, 0 ) );

    # we use the vbox here simply to give an outer border ...
    my $notify_vbox_b = Gtk2::VBox->new( 0, 0 );
    $notify_vbox_b->set_border_width(2);
    $notifybox_b->add($notify_vbox_b);

    my $notifybox = Gtk2::EventBox->new;
    $notifybox->modify_bg( 'normal',
        Gtk2::Gdk::Color->new( convert_hex_to_colour($background_popup) ) );
    $notify_vbox_b->pack_start( $notifybox, 0, 0, 0 );

    # we use the vbox here simply to give an internal border like padding
    my $notify_vbox = Gtk2::VBox->new( 0, 0 );
    $notify_vbox->set_border_width(7);
    $notifybox->add($notify_vbox);

    # display status
    my $status_hbox = Gtk2::HBox->new( 0, 0 );
    $notify_vbox->pack_start( $status_hbox, 0, 0, 0 );

    $hq_status_label = Gtk2::Label->new;
    $status = 'Consultando...' unless ($status);
    $hq_status_label->set_markup($status);
    $status_hbox->pack_start( $hq_status_label, 0, 0, 0 );

    $info_popup->add($notifybox_b);
}

# params: status text to show up in the popup onmouseover
sub update_popup_onmouseover {
    my ($status) = @_;

    build_popup_onmouseover($status);
    show_notify($info_popup) if ( $info_popup->visible );
}

# "checkGmail stuff modified"
# Display the notify onmouseover setting its position depending of the contents,
# the screen and the relative trayicon position.
sub show_notify {
    # get eventbox origin and icon height
    my ( $boxx, $boxy ) = $trayicon_box->window->get_origin;
    my $tray_icon_height = $trayicon_box->allocation->height;

    # get screen resolution
    my ( $monitor, $rect, $width, $height ) = get_screen( $boxx, $boxy );

    # if the tray icon is at the top of the screen, it's safe to move the window
    # to the previous window's position - this makes things look a lot smoother
    # (we can't do it when the tray icon's at the bottom of the screen, because
    # a larger window will cover the icon, and when we move it we'll get another
    # show_notify() event)
    $info_popup->move( $old_x, $old_y )
      if ( ( $boxy < ( $height / 2 ) ) && ( $old_x || $old_y ) );

    # show the window to get width and height
    $info_popup->show_all unless ( $info_popup->visible );
    my $notify_width  = $info_popup->allocation->width;
    my $notify_height = $info_popup->allocation->height;

    # calculate best position
    my $x_border = 4;
    my $y_border = 5;
    my $move_x =
        ( $boxx + $notify_width + $x_border > $width )
      ? ( $width - $notify_width - $x_border )
      : ($boxx);
    my $move_y =
        ( $boxy > ( $height / 2 ) )
      ? ( $boxy - $notify_height - $y_border )
      : ( $boxy + $tray_icon_height + $y_border );

    $info_popup->move( $move_x, $move_y ) if ( $move_x || $move_y );
    $info_popup->show_all unless ( $info_popup->visible );

    ( $old_x, $old_y ) = ( $move_x, $move_y );
}

# return: icons to be used in the app
sub load_icon_data {
    my ($icon_file) = @_;

    my $size   = 16;
    my $pixbuf = Gtk2::Gdk::Pixbuf->new_from_file($icon_file);
    $pixbuf->scale_simple( $size, $size, "hyper" );

    return $pixbuf;
}

sub time_message {
    my $day  = $daily_time->clone();
    my $week = $weekly_time->clone();

    if ( $punch_in_time ) {
        my $working_time = DateTime->now - $punch_in_time;
        $day  += $working_time;
        $week += $working_time;
    }

    # Format daily time
    my ($day_h, $day_m) = ($day->hours, $day->minutes);
    $day_m = ($day_m < 9 ? '0' : '').$day_m;
    $day  = "$day_h:$day_m";

    # Format weekly time
    my ($week_h, $week_m) = ($week->hours, $week->minutes);
    $week_m = ($week_m < 9 ? '0' : '').$week_m;
    $week_h += 24 * $week->days;
    $week = "$week_h:$week_m";

    return "Horas del día $day\nHoras de la semana $week";
}

# update the content of the popup showing the people at hq
sub update_info_hq {
    my $status;

    if (%currentPeople) {
        my $how_many = scalar( keys %currentPeople );
        $status = $how_many." ${COMPANY}er".( $how_many == 1 ? '' : 's' )
          . " working right now<b>:\n\t";
        $status .= join( "\n\t</b><b>", keys %currentPeople );
        $status .= '</b>';
    }
    else {
        $status = "Ningún ${COMPANY}er trabajando";
    }
    $status .= "\n\n".time_message();

    update_popup_onmouseover($status);
}

# called periodicaly
sub check {
    my %newPeople = whois_at_hq();

    # this does not work o_O
    #$am_i_punched = exists $newPeople{$NAME};
    foreach my $name ( keys %newPeople ) {
        $am_i_punched = ( $name eq $NAME );
        last if $am_i_punched;
    }
    if ( $am_i_punched ne $old_punched_status ) {
        change_state($am_i_punched);
        $old_punched_status = $am_i_punched;
    }
    my @join  = grep { not exists $currentPeople{$_} } keys %newPeople;
    my @leave = grep { not exists $newPeople{$_} } keys %currentPeople;

    print "join: @join leave: @leave\n" unless $silent;
    build_msg( \@join, \@leave );

    %currentPeople = %newPeople;

    update_info_hq();

    return 1;
}

# params: string like #EDAFEA and so on.
# returns: 3-int_array with the value of the colour
sub convert_hex_to_colour {
    my ($colour) = @_;
    my ( $red, $green, $blue ) = $colour =~ /#?(..)(..)(..)/;

    $red   = hex($red) * 256;
    $green = hex($green) * 256;
    $blue  = hex($blue) * 256;
    return ( $red, $green, $blue );
}

sub popup {
    # pops up a little message - disable by setting popup time to 0
    my ($popup_delay) = $popup_delay_in_seconds * 1000;
    return unless $popup_delay;

    my ( $text, $background ) = @_;

    # no point displaying if the user is already looking at the popup ..
    return if ( ($info_popup) && ( $info_popup->visible ) );

    $notify_popup->destroy if $notify_popup;

    $notify_popup = Gtk2::Window->new('popup');
    $notify_popup->set( 'allow-shrink', 1 );
    $notify_popup->set_border_width(2);
    $notify_popup->modify_bg( 'normal',
        Gtk2::Gdk::Color->new( 14756, 20215, 33483 ) );

    # the eventbox is needed for the background ...
    my $popupbox = Gtk2::EventBox->new;
    $popupbox->modify_bg( 'normal',
        Gtk2::Gdk::Color->new( convert_hex_to_colour($background) ) );

    # the hbox gives an internal border, and allows us to chuck an icon in, too!
    my $popup_hbox = Gtk2::HBox->new( 0, 0 );
    $popup_hbox->set_border_width(4);
    $popupbox->add($popup_hbox);

    my $popuplabel = Gtk2::Label->new;
    $popuplabel->set_line_wrap(1);

    $popuplabel->set_markup("$text");
    $popup_hbox->pack_start( $popuplabel, 0, 0, 3 );
    $popupbox->show_all;

    $notify_popup->add($popupbox);

    # get eventbox origin and icon height
    my ( $boxx, $boxy ) = $trayicon_box->window->get_origin;
    my $icon_height = $trayicon_box->allocation->height;

    # get screen resolution
    my ( $monitor, $rect, $width, $height ) = get_screen( $boxx, $boxy );

    # show the window to get width and height
    $notify_popup->show_all;
    my $popup_width  = $notify_popup->allocation->width;
    my $popup_height = $notify_popup->allocation->height;
    $notify_popup->hide;
    $notify_popup->resize( $popup_width, 1 );

    # calculate best position
    my $x_border = 4;
    my $y_border = 6;
    my $move_x =
        ( $boxx + $popup_width + $x_border > $width )
      ? ( $width - $popup_width - $x_border )
      : ($boxx);
    my $move_y =
        ( $boxy > ( $height / 2 ) )
      ? ( $boxy - $popup_height - $y_border )
      : ( $icon_height + $y_border );

    my $shift_y = ( $boxy > ( $height / 2 ) ) ? 1 : 0;

    $notify_popup->move( $move_x, $move_y );
    $notify_popup->show_all;

    # and popup ...
    for ( my $i = 1 ; $i <= $popup_height ; $i++ ) {
        my $move_y = ($shift_y) ? ( $boxy - $i - $y_border ) : $move_y;

        # move the window
        $notify_popup->move( $move_x, $move_y );
        $notify_popup->resize( $popup_width, $i );
        Gtk2->main_iteration while ( Gtk2->events_pending );

        select( undef, undef, undef, $animation_delay );
    }

    Glib::Timeout->add(
        $popup_delay,
        sub {
            popdown( $popup_height, $popup_width, $shift_y, $move_y, $boxy,
                $y_border, $move_x );
        }
    );
    return 0;
}

sub popdown {
    my ( $popup_height, $popup_width, $shift_y, $move_y, $boxy, $y_border,
        $move_x )
      = @_;

    for ( my $i = $popup_height ; $i > 0 ; $i-- ) {
        my $move_y = ($shift_y) ? ( $boxy - $i - $y_border ) : $move_y;

        # move the window
        $notify_popup->move( $move_x, $move_y );
        $notify_popup->resize( $popup_width, $i );
        Gtk2->main_iteration while ( Gtk2->events_pending );

        select( undef, undef, undef, $animation_delay );
    }

    $notify_popup->destroy;
}

# v main ----------------------------------------------------------------------

unless ( $user && $pass ) {
    print "Pon tu usuario y password CO!\n";
    exit;
}
unless ( $NAME ) {
    print "Pon tu nombre completo en \$NAME CO!\n";
    exit;
}
main();
