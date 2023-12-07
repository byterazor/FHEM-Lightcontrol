package main;
use strict;
use warnings;
use POSIX;
use Data::Dumper;
use JSON;

my $module_name="Z2M_SceneManager";
my $VERSION    = '0.0.1';


# wrapper for logging
sub Z2M_SceneManager_Log
{
  my $verbosity=shift;
  my $msg=shift;

  Log3 $module_name, $verbosity, $msg;
}


#
# Initialize the callback function of the module
#
sub Z2M_SceneManager_Initialize
{
    my ($hash) = @_;
    $hash->{DefFn}      = 'Z2M_SceneManager_Define';
    $hash->{ReadFn}     = undef;
    $hash->{ReadyFn}    = undef;
    $hash->{NotifyFn}   = 'Z2M_SceneManager_Notify';
    $hash->{UndefFn}    = undef;
    $hash->{DeleteFn}   = undef;
    $hash->{SetFn}      = 'Z2M_SceneManager_Set';
    $hash->{GetFn}      = undef;
    $hash->{AttrFn}     = undef;
    $hash->{AttrList}   = undef;
}

sub Z2M_SceneManager_UpdateGroupInfo
{
    my $hash                = shift;
    my $coordinator         = $hash->{COORDINATOR};
    my $groupDevice         = $hash->{GROUP_DEVICE};

    if (!IsDevice($coordinator))
    {
        warn("$coordinator is not a valid device name");
        return undef;    
    }

    if (!IsDevice($groupDevice))
    {
        warn("$groupDevice is not a valid device name");
        return undef;    
    }

    # fetch the devicetopic attribute from groupDevice
    my $deviceTopic = AttrVal($groupDevice, "devicetopic", undef);

    # fetch the friendly name of the group
    $deviceTopic =~ /\/(.*)$/;
    my $friendlyName = $1;

    readingsBeginUpdate($hash);
    readingsBulkUpdateIfChanged($hash, "FriendlyName", $friendlyName);

    # fetch groups from coordinaor readings
    my $groupReadings=ReadingsVal($coordinator,"groups",undef);
    if (!$groupReadings)
    {
        $hash->{STATE} = "group not found";
        Z2M_SceneManager_Log(1, "no groups found");
        return;
    }

    my $json_array = decode_json($groupReadings);

    # search for the group name
    my @groups = @{$json_array};
    for my $group (@groups)
    {
        if ($group->{friendly_name} eq $friendlyName)
        {
            $hash->{GroupID}= $group->{id};
            readingsBulkUpdateIfChanged($hash, "NR_Scenes", @{$group->{scenes}});
            my $sceneStr;
            my %scenes;
            for my $s (@{$group->{scenes}})
            {   
                $scenes{$s->{name}}=$s->{id};
                $sceneStr .= $s->{name} . ",";
            }
            chop($sceneStr);
            readingsBulkUpdateIfChanged($hash, "Scenes", $sceneStr);
            $hash->{helper}->{Scenes}=\%scenes;
        }
    }
    
    my $groupState=ReadingsVal($groupDevice,"state","unknown");
    readingsBulkUpdateIfChanged($hash, "state", $groupState);
    readingsEndUpdate($hash, 1);

}   



sub Z2M_SceneManager_Define
{
    my ($hash, $define) = @_;

    # ensure we have something to parse
    if (!$define)
    {
      warn("$module_name: no module definition provided");
      Z2M_SceneManager_Log(1,"no module definition provided");
      return;
    }

    # parse parameters into array and hash
    my($params, $h) = parseParams($define);

    my $name                = $params->[0];
    my $coordinator         = $params->[2];
    my $groupDevice         = $params->[3];
    

    # verify that $name is a valid and good fhem name
    if (!goodDeviceName($name))
    {
        return "$name is not a good definition name";
    }

    # verify that the coordinator device exists
    if (!IsDevice($coordinator))
    {
        return "$coordinator is not a valid device name";
    }
    
    # verify that the group device exists
    if (!IsDevice($groupDevice))
    {
        return "$groupDevice is not a valid device name";
    }


    $hash->{NAME}             = $name;
    $hash->{STATE}            = "initializing";
    $hash->{COORDINATOR}      = $coordinator;
    $hash->{GROUP_DEVICE}     = $groupDevice;

    readingsSingleUpdate($hash, "currentScene", "unknown" , 1);

    my $devspec = "global," . $coordinator . "," . $groupDevice;
    Z2M_SceneManager_Log(1,"created devspec of \"$devspec\"");
    setNotifyDev($hash,$devspec);

    return;
}

sub Z2M_SceneManager_Notify 
{
    my ($hash, $dev_hash) = @_;
    my $name = $hash->{NAME};

    return "" if(IsDisabled($name));

    if ($dev_hash->{NAME} eq "global")
    {
        my $events = deviceEvents($dev_hash,1);
        return if( !$events );
        foreach my $event (@{$events}) 
        {
            $event = "" if(!defined($event));

            if ($event eq "INITIALIZED")
            {
                Z2M_SceneManager_UpdateGroupInfo($hash);
            }
        }
    }

    if ($dev_hash->{NAME} eq $hash->{GROUP_DEVICE})
    {
        Z2M_SceneManager_UpdateGroupInfo($hash);
    }

}

# publish an mqtt topic and value
sub Z2M_SceneManager_Publish
{
    my $hash = shift;
    my $topic = shift;
    my $value = shift;

    # get the mqtt server the coordinator is connected to    
    my $coordinator = $hash->{COORDINATOR};
    my $mqttserver  = $defs{$coordinator}->{IODev};
    my $mqttserverName = $mqttserver->{NAME};

    fhem( "set $mqttserverName publish $topic $value");
}

# set the given scene for the group
sub Z2M_SceneManager_SetScene
{
    my $hash    = shift;
    my $scene   = shift;
    my $name    = $hash->{NAME};

    my $friendlyName = ReadingsVal($name, "FriendlyName", undef);

    foreach my $s (keys %{$hash->{helper}->{Scenes}})
    {
        if ($scene eq $s)
        {
            Z2M_SceneManager_Publish($hash, "zigbee2mqtt/" . $friendlyName . "/set",'{"scene_recall":' . $hash->{helper}->{Scenes}->{$s} .'}')
        } 
    }

    readingsSingleUpdate($hash, "currentScene", $scene , 0);

}

sub Z2M_SceneManager_GetNextScene
{
    my $hash = shift;
    my $currentScene = ReadingsVal($hash->{NAME}, "currentScene","unknown");
    my @scenes = split /,/, ReadingsVal($hash->{NAME},"Scenes",undef);

    if ($currentScene eq "unknown")
    {
        return $scenes[0];
    }

    my $nr = 0;
    foreach my $s (@scenes)
    {
        if ($s eq $currentScene)
        {
            last;
        }
        else
        {
            $nr++;
        } 
    }

    if ($nr >= @scenes-1)
    {
        return $scenes[0];
    }

    return $scenes[$nr+1];

}


sub Z2M_SceneManager_GetPreviousScene
{
    my $hash = shift;
    my $currentScene = ReadingsVal($hash->{NAME}, "currentScene","unknown");
    my @scenes = split /,/, ReadingsVal($hash->{NAME},"Scenes",undef);

    if ($currentScene eq "unknown")
    {
        return $scenes[0];
    }

    if (@scenes == 1)
    {
        return $scenes[0];
    }

    my $nr = 0;
    foreach my $s (@scenes)
    {
        if ($s eq $currentScene)
        {
            last;
        }
        else
        {
            $nr++;
        } 
    }

    if ($nr == 0 )
    {
        return $scenes[@scenes-1];
    }

    return $scenes[$nr-1];

}

sub Z2M_SceneManager_Set
{
    my ( $hash, $name, $cmd, @args ) = @_;
    
    return "\"set $name\" needs at least one argument" unless(defined($cmd));


    if ($cmd eq "nextScene")
    {
        Z2M_SceneManager_SetScene($hash,Z2M_SceneManager_GetNextScene($hash));
        return undef;
    }
    elsif ($cmd eq "previousScene")
    {
        Z2M_SceneManager_SetScene($hash,Z2M_SceneManager_GetPreviousScene($hash));
        return undef;
    }
    elsif ($cmd eq "scene")
    {
        my $scene = $args[0];

        my @scenes = split /,/,ReadingsVal($hash->{NAME},"Scenes","");
        if ( !grep( /^$scene$/, @scenes ) ) 
        {
            return "\"unknown scene \"$scene\"";
        }

        Z2M_SceneManager_SetScene($hash,$scene);
        return undef;

    }
    else
    {
        return "Unknown argument $cmd, choose one of nextScene:noArg previousScene:noArg scene:" . ReadingsVal($name,"Scenes","");
    } 
}


1;