package OGF::Util::Overpass;
use strict;
use warnings;
use Exporter;
use LWP;
use OGF::Util;
our @ISA = qw( Exporter );
our @EXPORT_OK = qw(
);


my $CMD_OSM3S_QUERY = '/opt/osm/osm3s/bin/osm3s_query';
my $CMD_OSMCONVERT  = 'osmconvert64';
my $URL_OVERPASS    = 'http://osm3s.opengeofiction.net/api/interpreter';



sub runQuery_local {
	my( $outFile, $queryText ) = @_;
	my $startTimeE = time();
	my( $osmFile, $pbfFile );
	if( $outFile =~ /\.pbf$/ ){
		($osmFile = $outFile) =~ s/\.pbf$//;
		$pbfFile = $outFile;
	}else{
		$osmFile = $outFile;
	}

	my $cmd = qq|$CMD_OSM3S_QUERY > "$osmFile"|;
	print STDERR "CMD: $cmd\n";
	local *OSM3S_QUERY;
	open( OSM3S_QUERY, '|-', $cmd ) or die qq/Cannot open pipe "$cmd": $!\n/;
	print OSM3S_QUERY $queryText;
	close OSM3S_QUERY;
	print STDERR 'Overpass export [1]: ', time() - $startTimeE, " seconds\n";

	if( $pbfFile ){
        OGF::Util::runCommand( qq|$CMD_OSMCONVERT "$osmFile" --out-pbf -o="$pbfFile"| );
        chmod 0644, $pbfFile; 
        print STDERR 'Overpass export [2]: ', time() - $startTimeE, " seconds\n";
        unlink $osmFile;
	}
}

sub runQuery_remote {
	my( $queryText ) = @_;
	my $startTimeE = time();

	my $userAgent = LWP::UserAgent->new(
		keep_alive => 20,
	);
	my $resp = $userAgent->post( $URL_OVERPASS, 'Content' => $queryText );
	my $data = $resp->content();

	print STDERR 'Overpass export [1]: ', time() - $startTimeE, " seconds\n";
	return $data;
}





1;
