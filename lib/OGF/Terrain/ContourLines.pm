package OGF::Terrain::ContourLines;
use strict;
use warnings;
use POSIX;
use OGF::View::TileLayer;
use OGF::Geo::Geometry;
use OGF::Util::File qw( writeToFile );
use OGF::Terrain::ElevationTile;



our $ELEVATION_TAG = 'ele';


sub writeContourTiles {
	my( $ctx, $tileLayer, $aTileSize, $hOpt ) = @_;
	$hOpt = {} if ! $hOpt;
	$aTileSize = [ 256, 256 ] if ! $aTileSize;

#	my $tileLayer = OGF::View::TileLayer->new( "contour:OGF:$level" );
	$tileLayer = OGF::View::TileLayer->new( $tileLayer ) if ! ref($tileLayer);
	my $hInfo = {
		_tileLayer => $tileLayer,
		_tileCache => {},
		_bbox      => [ 180, 90, -180, -90 ],
		_tileSize  => $aTileSize,
		_add       => ($hOpt->{'add'} ? 1 : 0),
	};
	if( $hOpt->{'bounds'} ){
	    my( $minLon, $minLat, $maxLon, $maxLat ) = ref($hOpt->{'bounds'}) ? @{$hOpt->{'bounds'}} : (split /,/, $hOpt->{'bounds'});
		my( $x0, $y1, $x1, $y0 ) = ( $tileLayer->geo2cnv($minLon,$minLat), $tileLayer->geo2cnv($maxLon,$maxLat) );
		$hInfo->{_bounds} = [ $x0, $y0, $x1, $y1 ];
		$hInfo->{_range}  = $tileLayer->bboxTileRange([$minLon, $minLat, $maxLon, $maxLat]);
	}

	my( @coastWays, @contourWays, @waterWays );
	foreach my $way ( values %{$ctx->{_Way}} ){
		my $hTags = $way->{'tags'};
		if( $hTags->{'natural'} && $hTags->{'natural'} eq 'coastline' ){  # handle coastline first to give it priority if "ele" tag is also present
			$way->{_elev} = 0;
			push @coastWays, $way;
		}elsif( $hTags && defined($hTags->{$ELEVATION_TAG}) ){
			next unless $hTags->{$ELEVATION_TAG} =~ /^-?[.\d]+$/;
			$way->{_elev} = $hTags->{$ELEVATION_TAG};
			push @contourWays, $way;
#			print STDERR "\%\$way <", join('|',%$way), ">\n";  # _DEBUG_
		}elsif( $hTags && $hTags->{'waterway'} ){
			push @waterWays, $way;
		}
	}
	if( scalar(@contourWays) == 0 ){
		die qq/ERROR: Found no contour ways.\n/
	}

	print STDERR "write contour ways\n";
	@contourWays = sort {$a->{_elev} <=> $b->{_elev}}  @contourWays;
	foreach my $way ( @contourWays, @coastWays ){
		writeElevationWay( $ctx, $way, $hInfo );
	}

	print STDERR "linear interpolation of waterways\n";
	my( $ct, $num ) = ( 0, scalar(@waterWays) );
	foreach my $way ( @waterWays ){
		++$ct;
		print STDERR "+ way ", $way->{'id'}, "  $ct/$num\n";
		my @isctAll;
		convertWayPoints( $ctx, $way, $hInfo );
		foreach my $wayC ( @contourWays, @coastWays ){
			next unless OGF::Geo::Geometry::rectOverlap( $way->{_rect}, $wayC->{_rect} );
			my @isct = OGF::Geo::Geometry::array_intersect( $way->{_points}, $wayC->{_points}, {'infoAll' => 1, 'rect' => [$way->{_rect},$wayC->{_rect}]} );
#			use Data::Dumper; local $Data::Dumper::Indent = 1; local $Data::Dumper::Maxdepth = 3; print STDERR Data::Dumper->Dump( [\@isct], ['*isct'] ), "\n";  # _DEBUG_
			map {$_->{_point}[2] = $wayC->{_elev}} @isct;
			push @isctAll, @isct if @isct;
		}
		next if ! @isctAll;
        $way->{_points} = addIntersectionPoints( $way->{_points}, \@isctAll );
        linearWayElevation( $way->{_points} );
        writeElevationWay( $ctx, $way, $hInfo );
	}

	my $proj = $tileLayer->projection();
    foreach my $node ( grep {$_->{'tags'} && defined $_->{'tags'}{$ELEVATION_TAG}} values %{$ctx->{_Node}} ){
        minMaxArea( $hInfo->{_bbox}, $node );
        my $pt = $proj->geo2cnv( [$node->{'lon'},$node->{'lat'}] );
        setElevationPoint( $pt, int($node->{'tags'}{$ELEVATION_TAG}), $hInfo );
    }

	unless( $hOpt->{'nosave'} ){
        saveElevationTiles( $hInfo );
        delete $hInfo->{_tileCache};
	}

	return $hInfo;
}



my $INT_MAX = 2 ** 31;


sub convertWayPoints {
	my( $ctx, $way, $hInfo ) = @_;
	my $proj = $hInfo->{_tileLayer}->projection();
	my $bbox = $hInfo->{_bbox};
	my $num = $#{$way->{'nodes'}};

	$way->{_points} = [];
	$way->{_rect}   = [ $INT_MAX, $INT_MAX, -$INT_MAX, -$INT_MAX ];
	for( my $i = 0; $i <= $num; ++$i ){
		my $node = $ctx->{_Node}{$way->{'nodes'}[$i]};
		my $pt = $proj->geo2cnv( [$node->{'lon'},$node->{'lat'}] );
		minMaxArea( $bbox, $node );
		minMaxArea( $way->{_rect}, $pt );
		$way->{_points}[$i] = $pt;		
	}
}

sub writeElevationWay {
	my( $ctx, $way, $hInfo ) = @_;
	convertWayPoints( $ctx, $way, $hInfo ) if ! $way->{_points};
	my $num = $#{$way->{_points}};
	print STDERR $way->{'id'}, " num=$num  elev=", $way->{_elev}, "\n";  # _DEBUG_

	for( my $i = 0; $i < $num; ++$i ){
		my( $ptA, $ptB ) = ( $way->{_points}[$i], $way->{_points}[$i+1] );
		( $ptA->[2], $ptB->[2] ) = ( $way->{_elev}, $way->{_elev} ) if defined $way->{_elev};
		next unless defined($ptA->[2]) && defined($ptB->[2]);
#		print STDERR "\$i <", $i, ">\n";  # _DEBUG_
		map {$_ = POSIX::floor($_+.5)} ( $ptA->[0], $ptA->[1], $ptB->[0], $ptB->[1] );
		my @linePoints = OGF::Geo::Geometry::linePoints( $ptA, $ptB );
		@linePoints = ( $ptA, @linePoints, $ptB );
		foreach my $pt ( @linePoints ){
			setElevationPoint( $pt, $pt->[2], $hInfo );
		}
	}
}

sub setElevationPoint {
	my( $pt, $elev, $hInfo ) = @_;
	my( $tx, $ty, $xt, $yt ) = $hInfo->{_tileLayer}->cnv2tile( $pt->[0], $pt->[1] );
#	print STDERR "$tx $ty - $xt $yt\n";  # _DEBUG_
	my $aTile = getTileArray( $hInfo, $tx, $ty );
	$aTile->[$yt][$xt] = POSIX::floor( $elev + .5 );
}

sub minMaxArea {
	my( $bbox, @nodes ) = @_;
	foreach my $node ( @nodes ){
        my( $x, $y ) = (ref($node) eq 'ARRAY')? ($node->[0],$node->[1]) : ($node->{'lon'},$node->{'lat'});
        $bbox->[0] = $x if $x < $bbox->[0];
        $bbox->[1] = $y if $y < $bbox->[1];
        $bbox->[2] = $x if $x > $bbox->[2];
        $bbox->[3] = $y if $y > $bbox->[3];
	}
}

sub addIntersectionPoints {
	my( $aPoints, $aIsctList ) = @_;
	@$aIsctList = sort {$a->{_idx} <=> $b->{_idx} || $a->{_ratio} <=> $b->{_ratio}} @$aIsctList;
#	use Data::Dumper; local $Data::Dumper::Indent = 1; local $Data::Dumper::Maxdepth = 3; print STDERR Data::Dumper->Dump( [$aIsctList], ['aIsctList'] ), "\n";  # _DEBUG_

	my @points;
	for( my $i = 0; $i <= $#{$aPoints}; ++$i ){
		push @points, $aPoints->[$i];
		my @idxPoints = map {$_->{_point}} grep {$_->{_idx} == $i} @$aIsctList;
		push @points, @idxPoints;
	}
	return \@points;
}

sub linearWayElevation {
	my( $aPoints ) = @_;
	my @elevIdx = grep {defined $aPoints->[$_][2]} (0..$#{$aPoints}); 
#	print STDERR "\@elevIdx <", join('|',@elevIdx), ">\n";  # _DEBUG_
	warn qq/linearElevation; no elevation point available\n/ if ! @elevIdx;
	for( my $i = 0; $i < $#elevIdx; ++$i ){
		linearSegmentElevation( $aPoints, $elevIdx[$i], $elevIdx[$i+1] );
	}
}

sub linearSegmentElevation {
	my( $aPoints, $i0, $i1 ) = @_;
#	print STDERR "linearSegmentElevation( $aPoints, $i0, $i1 )\n";  # _DEBUG_
	my( $zE, $zD ) = ( 2, 3 );

	$aPoints->[$i0][$zD] = 0;
	for( my $i = $i0; $i < $i1; ++$i ){
		my( $pt0, $pt1 ) = ( $aPoints->[$i], $aPoints->[$i+1] );
		my $dist = OGF::Geo::Geometry::dist( $pt0, $pt1 ); 
		$pt1->[$zD] = $pt0->[$zD] + $dist;
	}
	my( $e0, $e1 ) = ( $aPoints->[$i0][$zE], $aPoints->[$i1][$zE] );
	my $distTotal = $aPoints->[$i1][$zD];

	for( my $i = $i0+1; $i < $i1; ++$i ){
		my $pt = $aPoints->[$i];
		my $dd = $pt->[$zD];
		my $elevLin  = ($e1 * $dd + $e0 * ($distTotal - $dd)) / $distTotal;
#		print STDERR "[$i] \$elevLin <", $elevLin, ">\n";  # _DEBUG_
		$pt->[$zE] = $elevLin;
	}
}

sub getTileArray {
	my( $hInfo, $tx, $ty ) = @_;
	my $tag = "$tx:$ty";
	if( ! $hInfo->{_tileCache}{$tag} ){	
		my $tileName = $hInfo->{_tileLayer}->tileName( $tx, $ty );
		print STDERR "tileName: ", $tileName, "\n";  # _DEBUG_
		my( $wd, $hg ) = @{$hInfo->{_tileSize}};
		my $aTile;

		if( -f $tileName ){
			if( $hInfo->{_add} ){
				$aTile = OGF::Terrain::ElevationTile::makeArrayFromFile( $tileName, $wd, $hg, $OGF::Terrain::ElevationTile::BPP );
			}elsif( $hInfo->{_range} && rangeBoundary($hInfo->{_range},$tx,$ty) ){
				my $aRect = tileOverlap( $hInfo, $tx, $ty, $hInfo->{_bounds} );
				$aTile = OGF::Terrain::ElevationTile::makeArrayFromFile( $tileName, $wd, $hg, $OGF::Terrain::ElevationTile::BPP );
				clearSubtile( $aTile, $aRect, $OGF::Terrain::ElevationTile::NO_ELEV_VALUE );
			}
		}
		if( ! $aTile ){
			$aTile = OGF::Terrain::ElevationTile::makeTileArray( $OGF::Terrain::ElevationTile::NO_ELEV_VALUE, $wd, $hg );
		}
	
		$hInfo->{_tileCache}{$tag} = $aTile;
	}
	return $hInfo->{_tileCache}{$tag};
}

sub rangeBoundary {
	my( $hRange, $tx, $ty ) = @_;
	my( $y0, $y1, $x0, $x1	) = ( $hRange->{'y'}[0], $hRange->{'y'}[1], $hRange->{'x'}[0], $hRange->{'x'}[1] );
	return (($ty == $y0 || $ty == $y1) && ($tx >= $x0 && $tx <= $x1)) || (($tx == $x0 || $tx == $x1) && ($ty >= $y0 && $ty <= $y1));
}

sub tileOverlap {
    my( $hInfo, $tx, $ty, $aBounds ) = @_;
    my( $tlr, $wd, $hg ) = ( $hInfo->{_tileLayer}, @{$hInfo->{_tileSize}} );
    my( $x0, $y0, $x1, $y1 ) = ( $tlr->tile2cnv($tx,$ty,0,0), $tlr->tile2cnv($tx,$ty,$wd-1,$hg-1) );
    my $aRect = OGF::Geo::Geometry::rectOverlap( $aBounds, [$x0,$y0,$x1,$y1] );
    my( $tx0, $ty0, $xt0, $yt0 ) = $tlr->cnv2tile( $aRect->[0], $aRect->[1] );
    my( $tx1, $ty1, $xt1, $yt1 ) = $tlr->cnv2tile( $aRect->[2], $aRect->[3] );
	( $xt0, $yt0, $xt1, $yt1 ) = map {POSIX::floor($_)} ( $xt0, $yt0, $xt1, $yt1 );

    my( $dx, $dy, $maxX, $maxY ) = @{$tlr->{_tileOrder}};
    $xt0 = 0 if $tx0 < $tx;
    $yt0 = ($dy >= 0)? 0 : $hg-1 if $ty0 < $ty;
    $xt1 = $wd-1 if $tx1 > $tx;
    $yt1 = ($dy >= 0)? $hg-1 : 0 if $ty1 > $ty;
    return [ $xt0, $yt0, $xt1, $yt1 ];
}

sub clearSubtile {
    my( $aTile, $aClear, $val ) = @_;
    $val = 0 if ! $val;
    my( $x0, $y0, $x1, $y1 ) = @$aClear;
    for( my $y = $y0; $y <= $y1; ++$y ){
        for( my $x = $x0; $x <= $x1; ++$x ){
            $aTile->[$y][$x] = $val;
        }
    }
}

sub boundsFromFileName {
    my( $file ) = @_;
    my $aBounds;
#   if( $file =~ /_(\d+)([EW])(\d+)([NS])_band(\d+)_/ ){
    if( $file =~ /_([NS])(\d+)([EW])(\d+)_band(\d+)_/ ){
        my( $dNS, $minLat, $dEW, $minLon, $band ) = ( $1, $2, $3, $4, $5 );
		$minLon = -$minLon if $dEW eq 'W';
		$minLat = -$minLat if $dNS eq 'S';
        ( $minLon, $minLat, my $maxLon, my $maxLat ) = ( $minLon, $minLat+($band-1)*.2, $minLon+1, $minLat+$band*.2 );
        $aBounds = [ $minLon, $minLat, $maxLon, $maxLat ];
    }
    return $aBounds;
}



sub saveElevationTiles {
	my( $hInfo ) = @_;
	my $hTileCache = $hInfo->{_tileCache};
	my $hRange = setMinMaxRange();

	foreach my $key ( keys %$hTileCache ){
		my( $tx, $ty ) = split /:/, $key;
		setMinMaxRange( $hRange, $tx, $ty );
		my $tileName = $hInfo->{_tileLayer}->tileName( $tx, $ty );
		my $data = OGF::Terrain::ElevationTile::makeTileFromArray( $hTileCache->{$key}, $OGF::Terrain::ElevationTile::BPP );
		writeToFile( $tileName, $data, undef, {-bin => 1, -mdir => 1} );
	}
	$hInfo->{_tileRange} = $hRange;
}

sub setMinMaxRange {
	my( $hRange, $x, $y ) = @_;
	if( $hRange ){
		$hRange->{_xMin} = $x if $x < $hRange->{_xMin};
		$hRange->{_xMax} = $x if $x > $hRange->{_xMax};
		$hRange->{_yMin} = $y if $y < $hRange->{_yMin};
		$hRange->{_yMax} = $y if $y > $hRange->{_yMax};
	}else{
	    $hRange = { _xMin => 2**32, _xMax => 0, _yMin => 2**32, _yMax => 0 };
	}
	return $hRange;
}




1;
