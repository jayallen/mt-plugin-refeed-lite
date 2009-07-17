package MT::Plugin::Refeed_Lite;
use strict;
use warnings;

use base qw( MT::Plugin );

our $VERSION = '1.0';
my $plugin = MT::Plugin::Refeed_Lite->new({
    id                      =>  'refeed_lite',
    name                    =>  'Refeed_Lite',
    version                 => $VERSION,
    blog_config_template    => 'blog_config.tmpl',
    author_name             => 'Mark Stosberg',
    author_link             => 'http://mark.stosberg.com/bike',
    settings                => new MT::PluginSettings([
        [ 'feeds',  { Default => '', Scope => 'blog' } ],
        [ 'author', { Default => '', Scope => 'blog' } ],
    ]),
    description             =>  'Refeed Lite allows you to pull in RSS and Atom feeds automatically into your Movable Type-powered blog.',
});
MT->add_plugin( $plugin );

sub init_registry {
    my $plugin = shift;
    $plugin->registry({
        tasks => {
            CheckFeeds => {
                label       => 'Check for updates to feeds (Refeed Lite)',
                frequency   => 60 * 60,
                code        => sub {
                    check_feeds( $plugin );
                },
            },
        },
    });
}

sub check_feeds {
    my $plugin = shift;

    require DB_File;
    require Encode;
    require XML::FeedPP;

    require File::Spec;
    my $history = File::Spec->catfile(
        MT->instance->static_file_path, 'support', 'refeed-lite-history.db'
    );
    tie my %seen, 'DB_File', $history
        or die "Can't create history database $history: $!";

    my $warn = sub {
        my $log = MT::Log->new;
        $log->message( 'Refeed Lite: ' . $_[0] );
        $log->level( MT::Log->WARNING );
        MT->log( $log );
    };

    require MT::Author;
    require MT::Blog;
    my $iter = MT::Blog->search;
    while ( my $blog = $iter->() ) {
        my $feeds = $plugin->get_config_value( 'feeds', 'blog:' . $blog->id )
            or next;
        my @feeds = split /\n/, $feeds;

        my $name = $plugin->get_config_value( 'author', 'blog:' . $blog->id )
            or $warn->("No author defined for blog " . $blog->name), next;
        my( $author ) = MT::Author->search({ name => $name })
            or $warn->("No author by the name $name"), next;

        for my $line ( @feeds ) {
            my ($uri, $cat) = split /\|\|/, $line; 

            my $feed;
            eval { $feed = XML::FeedPP->new($uri) };
            if ($@) {
                $warn->("Can't find any feeds for $uri, skipping: $@");
                next;
            }

            for my $entry ($feed->get_item()) {
                my $entry_id = $entry->guid || $entry->link;

                next if $seen{ $blog->id . $entry_id };

                my $id_in_mt = post_to_mt( $author, $blog, $feed, $entry, $cat );
                MT->log(
                    sprintf "Refeed Lite: Posted entry %s ('%s') as entry %d",
                        $entry_id, $entry->title, $id_in_mt,
                );
                $seen{ $blog->id . $entry_id } = $id_in_mt;
            }
        }
    }
}

sub post_to_mt {
    my( $author, $blog, $feed, $feed_item, $category ) = @_;

#    ## Ensure time is set properly by converting to UTC here.
#    my $issued = $feed_item->pubDate;

    my $content = sprintf <<HTML, $feed_item->description, $feed_item->link, $feed->link, $feed->title;
%s

<p>Read <a href="%s">this entry</a> on <a href="%s">%s</a>.</p>
HTML

    require MT::Permission;
    my($perms) = MT::Permission->search({
        author_id   => $author->id,
        blog_id     => $blog->id,
    });


    my $date = _get_mt_date($feed_item->pubDate);

    require MT::Entry;
    my $new_entry = MT::Entry->new();
    $new_entry->title( $feed_item->title );
    $new_entry->text( $feed_item->description );
    $new_entry->author_id( $author->id );
    $new_entry->blog_id($blog->id);
    $new_entry->status( 2 ); # Go straight to 'published';
    $new_entry->authored_on( $date  );
    $new_entry->keywords( $feed_item->link ); 
    $new_entry->save
      or return 0;

    MT->log( sprintf "Refeed Lite: entry %s had date of %s", $new_entry->title, $date,);

    my $cat;
    my $place;
    if ( $category ) {
        require MT::Category;
        $cat = MT::Category->load( { label => $category } );
        # This would create the category if it doesn't already exist. 
        # unless ($cat) {
        #     if ( $perms->can_edit_categories ) {
        #         $cat = MT::Category->new();
        #         $cat->blog_id($blog->id);
        #         $cat->label( $category );
        #         $cat->parent(0);
        #         $cat->save
        #           or die $cat->errstr;
        #     }
        # }

        if ($cat) {
            require MT::Placement;
            $place = MT::Placement->new;
            $place->entry_id( $new_entry->id );
            $place->blog_id($blog->id);
            $place->category_id( $cat->id );
            $place->is_primary(1);
            $place->save
              or die $place->errstr;
        }

        MT->rebuild_entry(
            Entry             => $new_entry,
            BuildDependencies => 1,
        );
    }

# my $id = metaWeblog->newPost(
#         $blog->id,
#         '',
#         '',
#         {
#             title               => $feed_item->title,
#             description         => $feed_item->description,
#             #dateCreated         => $issued->iso8601 . 'Z',
#             dateCreated         => $feed_item->pubDate,
#             mt_convert_breaks   => 0,
#             mt_keywords         => $feed_item->link,
#         },
#         1,
#     );

    return $new_entry->id;
}

# Convert our date format into what MT expects
sub _get_mt_date {
    my$w3cdtf_date = shift;
    return unless defined $w3cdtf_date;

    my $w3cdtf_regexp = qr{
    ^(\d+)-(\d+)-(\d+)
    (?:T(\d+):(\d+)(?::(\d+)(?:\.\d*)?\:?)?\s*
    ([\+\-]\d+:?\d{2})?|$)
    }x;
    my ( $year, $mon, $mday, $hour, $min, $sec, $tz ) = ( $w3cdtf_date =~ $w3cdtf_regexp );
    # XXX We could calculate timezone offset here. 
    return unless ( $year > 1900 && $mon && $mday );
    $hour ||= 0;
    $min ||= 0;
    $sec ||= 0;

    # Building this format: YYYYMMDDHHMMSS
    return sprintf( '%04d%02d%02d%02d%02d%02d', $year, $mon, $mday, $hour, $min, $sec );


}

1;
