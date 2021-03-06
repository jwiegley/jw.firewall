#!/usr/bin/env ruby

##############################################################################
#
# firewall.rb
#
#   version 2.00 (2008/04/20) by John Wiegley <johnw@newartisans.com>
#
# This script takes a series of arguments describing the current network
# interfaces and the networks behind them.  Basic usage is:
#
#   firewall.rb [OPTIONS] [INTERFACES...]
#
# The list of INTERFACES specifies which interfaces and networks you know
# about, and their respective level of trust.
#
# NOTE: Interfaces/networks which are not mentioned are completely shut out
# and *not logged*.  This means that if no interfaces are given, the effect is
# to shut out networking entirely, except for DHCP and certain types of ICMP.
# This is not a bad idea as a default after startup, until you know what your
# networking environment looks like.
#
# An INTERFACE may be just an interface name, in which case traffic is not
# filtered by a netmask.  This is important for interfaces that will access
# addresses outside of their own range, such as those wishing to reach the
# Internet.  If a network base address and mask is given after an @-symbol, it
# specifies legal address ranges for that interface: this is used to check for
# spoofing and illegal addresses.  If two @-symbols are used, the network is
# considered "trusted" and additional traffic, such as Rendezvous, is allowed.
# If three @-symbols are used, the network is considered a trusted Windows
# network, not Mac.
#
# Examples:
#
#   en1{0,0}                      en1 (Airport) accesses the Internet
#                                 and uses priority packet queueing,
#                                 but without rate limiting
#   en0:192.168.0.0/24            Local network on en0: 192.168.0.x
#   en0::192.168.0.0/16           Trusted network on en0: 192.168.x.x
#   en0::192.168.0.0:255.255.0.0  Same as the one immediately above
#   en0+mac::192.168.0.0/16       Trusted Mac network on en0
#   en0+win::192.168.0.0/16       Trusted Windows network on en0
#   en0+mac+win::192.168.0.0/16   Trusted mixed network on en0
#
# The same interface can appear multiple times, if you have several networks
# connected to it (such as having your router's local network, and the
# Internet, both visible over en1).  NOTE: *In the case, always list the most
# specific interfaces/networks first*.  This means that if you access both
# 192.168.0.0/24 and the Internet over en1, use this:
#
#   rc.firewall en1::192.168.0.0/24 'en1{0,0}'
#
# The string {0,0} (escaped for the shell) specifies inbound and outbound
# bandwidth limits for public interfaces.  A pair of zeros means bandwith
# isn't limited, but it IS shaped -- under the assumption that resources
# probably ARE limited, you just don't want to specify an artifical number
# right now.  If the "{IN,OUT}" isn't specified for an interface, it means
# neither limiting nor shaping is performed.
#
# NOTE: A deficiency of this script is that I limit/shape based on the
# interface, not the network; to compensate, traffic bound for internal
# networks is never limited or shaped.
#
# OPTIONS can be one or more of the following:
#
# --debug
#   Show what commands would have been executed to setup the firewall.
#   No system changes are made.
#
# --log-all
#   Log every rejected packet, not just the suspicious ones.  Note: If
#   you're restarting the firewall, you'll initially reject a lot of
#   established packets from connections made before the restart.
#
# --stealth
#   Try to be as stealthy as possible.  Ordinarily, this script
#   responds to failed connection attempts in the following manner:
#
#     port 113                      TCP RESET
#     broadcasts                    ICMP host-prohib
#     connections                   ICMP filter-prohib
#     old established connections   TCP RESET
#     NetBIOS/Rendezvous traffic    silently drop packet
#
#   Also, while all "normal" outbound traffic is silently allowed,
#   anything out of the ordinary is logged.
#
#   When --stealth mode is on, this script will drop all inbound
#   packets, and also all suspicious outbound packets.  It tries to
#   make your machine appear as far under the radar as possible on
#   an open network.
#
#   However, do realize that being entirely stealthy is not
#   possible.  Anyone on the same local network as you will be able
#   to see the ARP packets flying around, and will know that you are
#   there and what your MAC address is.  Also, by attempting to scan
#   you, they will know that you're trying to be stealthy.  In fact,
#   --stealth mode is really only effective against the most casual
#   of observers, and not a determined analyst.
#
# --blackhole
#   If used, a tcp/udp blackhole is configured to help block stealth
#   scanning.  Note however that this has caused known slowdowns in
#   services like Samba (smbfs).
#
# --router INTF1,INTF2@NET
#   This machine acts as a router between INTF1 and INTF2 in network
#   NET.  INTF1 specifies the target interface, so if you wanted to
#   route traffic from en1 (local clients connected to your Airport
#   network) over en0 (cable modem connection to the Internet), you
#   would use: --router en0,en1; which you might read as "route
#   traffic over en0 from en1".
#
# --tcp PORT[,PORT...]
# --udp PORT[,PORT...]
#   Make the given inbound PORTs accessible on any configured
#   interface.
#
# --local-tcp PORT[,PORT...]
# --local-udp PORT[,PORT...]
#   Make the given inbound PORTs accessible to local networks (i.e.,
#   just not the Internet).
#
# --trusted-tcp PORT[,PORT...]
# --trusted-udp PORT[,PORT...]
#   Make the given inbound PORTs accessible to trusted networks only.
#
# EXAMPLE
#
# en1 (Airport) is connected to the Internet; there is also a local network
# visible on en1; there is a trusted Mac network on en0; and I'm connected
# via OpenVPN (over tap0) to a trusted Windows network:
#
#   rc.firewall			\
#       en1:192.168.0.0/24	\
#       'en1{0,0}'		\
#       en0+mac::192.168.2.0/24 \
#       tap0+win::10.9.19.0/24
#
# NOTES
#
# A word about a few of the things this script cannot do, owing to
# deficiencies with ipfw on Mac OS X 10.4 and 10.5:
#
# * You cannot filter incoming packets based on the MAC address of the source.
#   This is because the necessary support is not compiled into the OS X
#   kernel, not because ipfw doesn't support it.
#
# * You cannot take action based on counters, like shutting off ECHO REQUEST
#   packets from a certain host once they exceed a certain number within a
#   given set of time.  Tools like IPNetSentryX can do this.
#
# * Although you can shape traffic by directing it along specific pipes or
#   queues, you cannot manipulate traffic as it passes down the chain.  Doing
#   this requires divert'ing the traffic to a user-space daemon, which
#   modifies the packets and passes them on (google for 'throttled').
#   iptables on Linux can do this sort of thing very easily; it's a shame ipfw
#   cannot.
#
# * You can't match a packet based on its IP fragment offset, only on the
#   existence of fragmentation or not.  And ipfw always drops TCP packets with
#   a fragment offset of 1.
#
##############################################################################


##############################################################################
#
# Process command-line options
#
##############################################################################

IPFW="/sbin/ipfw -q"

debug=false
blackhole=false
router=false
this="me"
logall=""

stealth=false
tcp_reset="reset"
unreach_host="unreach host"	# aka, reject
unreach_host_prohib="unreach host-prohib"
unreach_filter_prohib="unreach filter-prohib"

trusted_tcp_ports=""
trusted_udp_ports=""
local_tcp_ports=""
local_udp_ports=""
public_tcp_ports=""
public_udp_ports=""

while [[ -n "$1" ]] && (echo $1 | grep -q -e ^--); do
    case "$1" in
    --debug)
	shift 1
	debug=true
	IPFW="echo ipfw" ;;

    --log-all)
	shift 1
	echo Logging all denied packets
        logall="log" ;;

    --stealth)
	shift 1
	echo Enabling stealth mode to avoid detection and leakage
	tcp_reset="drop"
	unreach_host="drop"	# aka, reject
	unreach_host_prohib="drop"
	unreach_filter_prohib="drop"
        stealth="true" ;;

    --blackhole)
	shift 1
	echo Enabling blackhole to avoid stealth port scans
        blackhole="true" ;;

    --router)
	shift 1
	router=true
	external_intf=$(echo $1 | sed 's/,.*//')
	client_intf=$(echo $1 | sed 's/.*,//')
	client_net=$(echo $client_intf | sed 's/.*@//')
	client_intf=$(echo $client_intf | sed 's/@.*//')
	echo Enabling routing $client_intf \($client_net\) -\> $external_intf
	shift 1;;

    --trusted-tcp)
	shift 1
	if [[ -n "$trusted_tcp_ports" ]]; then
	    trusted_tcp_ports="$trusted_tcp_ports,$1"
	else
	    trusted_tcp_ports="$1"
	fi
	echo Opening trusted TCP ports: $trusted_tcp_ports
	shift 1 ;;

    --local-tcp)
	shift 1
	if [[ -n "$local_tcp_ports" ]]; then
	    local_tcp_ports="$local_tcp_ports,$1"
	else
	    local_tcp_ports="$1"
	fi
	echo Opening local TCP ports: $local_tcp_ports
	shift 1 ;;

    --tcp)
	shift 1
	if [[ -n "$public_tcp_ports" ]]; then
	    public_tcp_ports="$public_tcp_ports,$1"
	else
	    public_tcp_ports="$1"
	fi
	echo Opening public TCP ports: $public_tcp_ports
	shift 1 ;;

    --trusted-udp)
	shift 1
	if [[ -n "$trusted_udp_ports" ]]; then
	    trusted_udp_ports="$trusted_udp_ports,$1"
	else
	    trusted_udp_ports="$1"
	fi
	echo Opening trusted UDP ports: $trusted_udp_ports
	shift 1 ;;

    --local-udp)
	shift 1
	if [[ -n "$local_udp_ports" ]]; then
	    local_udp_ports="$local_udp_ports,$1"
	else
	    local_udp_ports="$1"
	fi
	echo Opening local UDP ports: $local_udp_ports
	shift 1 ;;

    --udp)
	shift 1
	if [[ -n "$public_udp_ports" ]]; then
	    public_udp_ports="$public_udp_ports,$1"
	else
	    public_udp_ports="$1"
	fi
	echo Opening public UDP ports: $public_udp_ports
	shift 1 ;;

    *)
	echo Unrecognized option $1
	exit 1
    esac
done


##############################################################################
#
# If interfaces were given, setup the global variables used by all the
# rules.
#
##############################################################################

args="$@"

declare -a interfaces
declare -a networks
declare -a trust
declare -a nettype
declare -a inbw
declare -a outbw
declare -a all_intf

intf_count=0

function add_interface() 
{
    intf=$1
    netw=$2
    trusted=$3
    ntype=$4
    intf_inbw=$5
    intf_outbw=$6

    interfaces[$intf_count]=$intf
    networks[$intf_count]=$netw
    trust[$intf_count]=$trusted
    nettype[$intf_count]=$ntype
    inbw[$intf_count]=$intf_inbw
    outbw[$intf_count]=$intf_outbw

    echo Configuring interface $intf_count: $intf $netw \
	trusted? $trusted type $ntype \
	\(in $intf_inbw out $intf_outbw\)

    # Configure bandwith shaping in/out pipes for each interface that
    # has a bandwith defined
    if [[ -n "$intf_inbw" ]]; then
	$IPFW pipe $((100 + intf_count)) config bw 0
	$IPFW pipe $((200 + intf_count)) config bw 0
    fi

    # If the interface is not yet in the `all_intf' array, add it
    if echo ${all_intf[@]} | grep -qv "\\<$intf\\>"; then
	all_intf=(${all_intf[@]} $intf)
    fi

    intf_count=$((intf_count + 1))
}

while [[ -n "$1" ]]; do
    intf=""
    netw=any
    trusted=false
    ntype=unknown

    intf=$(echo "$1" | sed 's/[+:].*//')
    netw=$(echo "$1" | sed 's/^[^:]*:*//')

    if [[ -z "$netw" ]]; then
	netw=any
    fi

    if echo "$1" | grep -q "::"; then
	trusted=true
    fi

    if echo "$1" | grep -q "\\+mac"; then
	ntype=mac
    fi

    if echo "$1" | grep -q "\\+win"; then
	if [[ $ntype == mac ]]; then
	    ntype=both
	else
	    ntype=win
	fi
    fi

    if echo "$intf" | grep -q "{"; then
	intf_inbw=$(echo "$intf" | sed 's/.*{//' | sed 's/,.*//' | sed 's/}//')
	intf_outbw=$(echo "$intf" | sed 's/.*{//' | sed 's/.*,//' | sed 's/}//')
	intf=$(echo "$intf" | sed 's/{.*//')
    else
	intf_inbw=""
	intf_outbw=""
    fi

    add_interface $intf $netw $trusted $ntype $intf_inbw $intf_outbw

    shift 1
done

via_all=""

if [[ $intf_count > 0 ]]; then
    for intf in ${all_intf[@]}; do
	if [[ -z "$via_all" ]]; then
	    via_all="{"
	else
	    via_all="$via_all or"
	fi
	via_all="$via_all via $intf"
    done

    if [[ -n "$via_all" ]]; then
	via_all="$via_all }"
    fi
fi


##############################################################################
#
# Function for rate limiting/traffic shaping an interface
#
##############################################################################

declare -a limited

function limit_intf()
{
    intf=$1
    intf_index=""

    for (( i=0; i < intf_count; i++ )); do
	if [[ ${interfaces[$i]} == $intf && \
	      -z "${limited[$i]}" && -n "${inbw[$i]}" ]]; then
	    limited[$i]=true

    # Put a pipe in place for all remaining inbound/outbound traffic,
    # which can be throttled using the option --setrate or the
    # separate script "setrate".  This makes it easy to be kind to
    # other people's networks, no matter what kind of traffic it is.
    inpipe="pipe $((100 + i))"
    outpipe="pipe $((200 + i))"

    $IPFW $inpipe config bw ${inbw[$i]}
    $IPFW $outpipe config bw ${outbw[$i]}
    
    private="192.168.0.0/16,172.16.0.0/12,10.0.0.0/8"

    $IPFW add 450 set 0 skipto 900 all from any to $private out via $intf
    $IPFW add 460 set 0 skipto 900 all from $private to any in via $intf

    $IPFW add 500 set 0 $inpipe tcp from any to any in via $intf tcpflags !syn
    $IPFW add 510 set 0 $inpipe udp from any to any in via $intf

    # Shape the outbound pipe so that some protocols get priority going
    # out
    $IPFW queue $((100 + i)) config $outpipe weight 7 # high-priority
    $IPFW queue $((200 + i)) config $outpipe weight 5 # medium-priority
    $IPFW queue $((300 + i)) config $outpipe weight 1 # low-priority
    
    # Assign outgoing empty/small ACK packets to the high-priority queue
    $IPFW add 600 set 0 queue $((100 + i)) \
        tcp from any to any out via $intf tcpflags ack iplen 0-80
    
    # Assign outgoing UDP (DNS) and SSH traffic to the medium-priority queue
    $IPFW add 700 set 0 queue $((200 + i)) tcp from any to any 22,80,443,5900 \
	out via $intf \{ tcpflags \!ack or iplen 81-65535 \}
    $IPFW add 710 set 0 queue $((200 + i)) udp from any to any 53,1194 out via $intf
    
    # Assign all other outgoing traffic to the low-priority queue:
    $IPFW add 800 set 0 queue $((300 + i)) tcp from any to any not 22,80,443,5900 \
	out via $intf \{ tcpflags \!ack or iplen 81-65535 \}
    $IPFW add 810 set 0 queue $((300 + i)) udp from any to any not 53,1194 out via $intf

	fi
    done
}


##############################################################################
#
# Initialize and tune the firewalling environment
#
##############################################################################

# Remove any rules previously defined and flush the dynamic tables
$IPFW -f flush
$IPFW -f pipe flush

# Log all rejected packets, which are always "suspect"
if [[ $debug == false ]]; then
    #sysctl -w net.inet.ip.fw.verbose=1
    sysctl -w net.inet.ip.fw.verbose=0

    # Make sure packets get reinjected
    sysctl -w net.inet.ip.fw.one_pass=0
    # Check that packets are appropriate to their interface
    sysctl -w net.inet.ip.check_interface=1
    # Up to 65535 for faster downloads when you have decent
    # latency-free bandwidth (ie, _not_ DSL which dies badly as it
    # saturates)
    sysctl -w net.inet.tcp.sendspace=16000
    sysctl -w net.inet.tcp.recvspace=16000
    sysctl -w net.inet.udp.recvspace=42080
    sysctl -w net.inet.raw.recvspace=8192
    sysctl -w net.local.dgram.maxdgram=4196
    # Other network buffering
    sysctl -w net.local.stream.recvspace=16000
    sysctl -w net.local.stream.sendspace=16000
    sysctl -w net.local.dgram.recvspace=8000
    # Turn on RFC1323 TCP high speed optimization.
    # NOTE: This can be a security risk (DoS attack)
    sysctl -w net.inet.tcp.rfc1323=1
    # ICMP limit
    sysctl -w net.inet.icmp.icmplim=1024
    # Stop redirects
    sysctl -w net.inet.icmp.drop_redirect=1
    sysctl -w net.inet.icmp.log_redirect=1
    sysctl -w net.inet.ip.redirect=0
    # Stop source routing
    sysctl -w net.inet.ip.sourceroute=0
    sysctl -w net.inet.ip.accept_sourceroute=0
    # Stop broadcast ECHO response
    sysctl -w net.inet.icmp.bmcastecho=0
    # Stop other broadcast probes
    sysctl -w net.inet.icmp.maskrepl=0
    # TCP delayed ack on
    sysctl -w net.inet.tcp.delayed_ack=1
    # Turn on strong TCP sequencing
    sysctl -w net.inet.tcp.strict_rfc1948=1
    # Socket queue defense against SYN attacks
    sysctl -w kern.ipc.somaxconn=1024
    # IPC max buffering
    sysctl -w kern.ipc.maxsockbuf=523288
    # ARP cleanup
    sysctl -w net.link.ether.inet.max_age=1200

    # Create a blackhole to avoid stealth port scans
    if [[ $blackhole == true ]]; then
	sysctl -w net.inet.tcp.blackhole=2
	sysctl -w net.inet.udp.blackhole=1
    else
	sysctl -w net.inet.tcp.blackhole=0
	sysctl -w net.inet.udp.blackhole=0
    fi

    # If we're acting as a router, enable packet forwarding
    if [[ $router == true ]]; then
	sysctl -w net.inet.ip.forwarding=1
    else
	sysctl -w net.inet.ip.forwarding=0
    fi
fi


##############################################################################
#
# Set 0: Allow loopback, divert NAT packets, shape ICMP/TCP-SYN
#
##############################################################################

# Allow all loopback traffic, don't bother with anything else
$IPFW add 100 set 0 allow all from any to any via 'lo*'

if [[ $router == true ]]; then
    # Divert traffic from the external interface to the nat daemon
    # (note: using "in" here, as some firewalls do, causes OpenVPN to
    # stop working)
    $IPFW add 200 set 0 divert natd all from any to any via $external_intf
fi

# Rate limit TCP traffic used to establish connections, to protect
# against SYN flooding
$IPFW pipe 300 config bw 64Kbit/s queue 5

$IPFW add 300 set 0 pipe 300 tcp from any to any in setup

# Delay TCP RESET packets.  From the IPNetSentryX docs: "Some
# firewalls can send TCP RESET segments when denying access. If the
# interface running such a firewall is set to promiscuous mode, the
# firewall may send TCP RESET segments in response to connection
# requests that were not originally addressed to that host. The
# symptom is frequent “Connection refused” responses when trying to
# access remote servers. By delaying such TCP RESET segments
# (approximately 0.5 seconds), we allow the actual target of the
# connection request (if any) to respond first completing the
# connection process. When the RESET arrives, it will be safely
# ignored as out of order if the target host has already responded."
$IPFW pipe 350 config delay 500

$IPFW add 350 set 0 pipe 350 tcp from any to any in tcpflags rst

# Rate limit ICMP traffic to avoid line clogging by Smurf attacks
$IPFW pipe 400 config bw 16Kbit/s queue 1
$IPFW pipe 410 config bw 16Kbit/s queue 5

$IPFW add 410 set 0 pipe 400 icmp from any to any in
$IPFW add 415 set 0 pipe 410 icmp from any to any out

# Rules 500-899 are defined by limit_intf() above

$IPFW add 901 set 0 deny log all from any to any ipoptions rr in $via_all
$IPFW add 911 set 0 deny log all from any to any ipoptions ts in $via_all
$IPFW add 921 set 0 deny log all from any to any ipoptions lsrr in $via_all
$IPFW add 931 set 0 deny log all from any to any ipoptions ssrr in $via_all

$IPFW add 941 set 0 deny log tcp from any to any tcpflags syn,fin
$IPFW add 951 set 0 deny log tcp from any to any tcpflags syn,rst
$IPFW add 961 set 0 deny log tcp from any 0 to any
$IPFW add 971 set 0 deny log tcp from any to any 0
$IPFW add 981 set 0 deny log udp from any 0 to any
$IPFW add 991 set 0 deny log udp from any to any 0


##############################################################################
#
# Set 1: Allow routed traffic
#
# If this machine is acting as a router, allow traffic to pass through
# between the two connected interfaces.
#
##############################################################################

if [[ $router == true ]]; then
    # Allow traffic coming in from the "client" network, and traffic
    # coming in from the Internet bound for the client network
    $IPFW add 1000 set 1 allow all from $client_net to any in recv $client_intf
    $IPFW add 1010 set 1 allow all from any to $client_net in recv $external_intf

    # And allow this traffic out through the respective target interface
    $IPFW add 1100 set 1 allow all \
	from $client_net to any out recv $client_intf xmit $external_intf
    $IPFW add 1110 set 1 allow all \
	from any to $client_net out recv $external_intf xmit $client_intf

    # Also allow the client network to see the router
    $IPFW add 1200 set 1 allow all from $client_net to me out recv $client_intf
    $IPFW add 1210 set 1 allow all from me to $client_net out xmit $client_intf
fi


##############################################################################
#
# Set 2: Allow traffic relating to ongoing conversations
#
# But deny fragments and established connections not so related.
#
##############################################################################

# Allow traffic if it matches the dynamic table
$IPFW add 2000 set 2 check-state

# Drop fragments and reset established connections not matched by the
# dynamic table
$IPFW add 2100 set 2 deny $logall all from any to any frag
$IPFW add 2110 set 2 $tcp_reset $logall tcp from any to any established


##############################################################################
#
# Set 3: Allow Rendezvous and AFP for Apple networks
#
##############################################################################

# TCP  548        Apple    AFP
#      5009       Apple    Airport Express Admin

tcp_ports=548,5009

# UDP  192        Apple    UPnP (network discovery)

udp_ports=192

allowed=false

for (( index=0; index < intf_count; index++ )); do
    if [[ ${nettype[$index]} == mac || ${nettype[$index]} == both ]]; then
	netw=${networks[$index]}
	intf=${interfaces[$index]}

	# Allow outbound and inbound TCP connections to tcp_ports
	$IPFW add $((3100 + index)) set 3 allow $logall \
	    tcp from $netw to $netw $tcp_ports via $intf setup keep-state

	# Allow outbound and inbound UDP connections to udp_ports
	$IPFW add $((3200 + index)) set 3 allow $logall \
	    udp from $netw to $netw $udp_ports via $intf keep-state

	# Allow Rendezvous (Zeroconf) traffic
	$IPFW add $((3300 + index)) set 3 allow $logall \
	    udp from $netw to any 5353 via $intf keep-state

	# Allow three types of broadcast traffic typically found in
	# Windows and Apple enviroments
	$IPFW add $((3400 + index)) set 3 allow $logall \
	    ip from $netw to 224.0.0.0/3 via $intf keep-state
	$IPFW add $((3410 + index)) set 3 allow $logall \
	    udp from $netw to 239.255.255.253 via $intf keep-state
	$IPFW add $((3420 + index)) set 3 allow $logall \
	    udp from $netw to 255.255.255.255 via $intf keep-state

	allowed=true
    fi
done

# Load or unload the Apple Multicast daemon based on whether we're
# using Rendezvous at all; no need to broadcast if we're not, since
# the packets won't even be let out
if [[ $allowed == false && $debug == false ]]; then
    launchctl unload \
	/System/Library/LaunchDaemons/com.apple.mDNSResponder.plist 2> /dev/null
elif [[ $allowed == true && $debug == false ]]; then
    launchctl load -w /System/Library/LaunchDaemons/com.apple.mDNSResponder.plist
fi


##############################################################################
#
# Set 4: Allow NetBIOS and SMB for Windows networks
#
##############################################################################

# TCP  135-139    Windows  File sharing (http://support.microsoft.com/kb/298804)
#      445        Windows  Direct-hosted SMB traffic (same URL)
#      5000       Windows  UPnP

tcp_ports=135-139,445,5000

# UDP  135-139    Windows  File sharing (see above)
#      427        Windows  SLP (Service Location Protocol)
#      445        Windows  Direct-hosted SMB traffic
#      1900       Windows  UPnP

udp_ports=135-139,427,445,1900

for (( index=0; index < intf_count; index++ )); do
    if [[ ${nettype[$index]} == win || ${nettype[$index]} == both ]]; then
	netw=${networks[$index]}
	intf=${interfaces[$index]}

	# Allow outbound and inbound TCP connections to tcp_ports
	$IPFW add $((4100 + index)) set 4 allow $logall \
	    tcp from $netw to $netw $tcp_ports via $intf setup keep-state

	# Allow outbound and inbound UDP connections to udp_ports
	$IPFW add $((4200 + index)) set 4 allow $logall \
	    udp from $netw to $netw $udp_ports via $intf keep-state

	# Allow three types of broadcast traffic typically found in
	# Windows and Apple enviroments
	$IPFW add $((4300 + index)) set 4 allow $logall \
	    ip from $netw to 224.0.0.0/3 via $intf keep-state
	$IPFW add $((4320 + index)) set 4 allow $logall \
	    udp from $netw to 239.255.255.253 via $intf keep-state
	$IPFW add $((4340 + index)) set 4 allow $logall \
	    udp from $netw to 255.255.255.255 via $intf keep-state
    fi
done


##############################################################################
#
# Set 5: Allow certain kinds of traffic for trusted networks
#
##############################################################################

for (( index=0; index < intf_count; index++ )); do
    if [[ ${trust[$index]} == true ]]; then
	netw=${networks[$index]}
	intf=${interfaces[$index]}

	# Allow all ICMP traffic within trusted networks (aka ping)
	$IPFW add $((5100 + index)) set 5 allow $logall \
	    icmp from $netw to $netw via $intf
    fi
done

# Reject broadcast traffic (possibly related to Rendezvous/NetBIOS)
$IPFW add 5200 set 5 $unreach_host_prohib $logall ip from any to 224.0.0.0/3 not 67-68
$IPFW add 5210 set 5 $unreach_host_prohib $logall ip from any to 239.255.255.253 not 67-68
$IPFW add 5220 set 5 $unreach_host_prohib $logall ip from any to 255.255.255.255 not 67-68

# Deny Windows and Apple network related UDP traffic reaching this
# point; reject TCP with host-prohib
$IPFW add 5300 set 5 deny $logall udp from any to any $udp_ports
$IPFW add 5310 set 5 $unreach_host_prohib $logall tcp from any to any $tcp_ports


##############################################################################
#
# Set 6: Allow in/out packets related to DHCP and some ICMP
#
# This rule set allows our network interfaces to be configured.  It can
# be skipped if DHCP is not being used; it could also be disabled once
# an address is assigned, although only for as long as the lease will
# last.
#
##############################################################################

# Allow certain types of ICMP packets on known interfaces, which might
# be necessary for proper operation
$IPFW add 6000 set 6 allow $logall icmp from any to any \
    icmptypes 0,3,4,11,12,13,14 $via_all keep-state

# Allow DHCP packets in and out, including broadcast
$IPFW add 6100 set 6 allow $logall udp from any 67-68 to any 67-68 $via_all keep-state


##############################################################################
#
# Set 7: Filter inbound traffic
#
# Stateful firewalling is used to allow in packets related to
# established outbound connections.  Filtering is used to remove
# possible spoof packets.  The remainder might be consider "legitimate
# inbound requests", and are passed to the subsequent rule sets.
#
##############################################################################

# Verify reverse path to help avoid spoofed packets.  This means any
# packet coming from a particular interface must have an address
# matching the netmask for that interface.  The `via_all' variable is
# used to avoid logging packets on interfaces we're not interested in.
$IPFW add 7000 set 7 deny $logall all from any to any not verrevpath in $via_all

# Reject anything received that was not directly intended for this
# matchine with a "host prohibited" response.  This mostly means
# broadcast.  We omit DHCP from this because until a DHCP lease is
# given, we have no idea what our address is/will be.
$IPFW add 7100 set 7 $unreach_host_prohib log all from any to not me not 67-68 in $via_all
$IPFW add 7110 set 7 $unreach_host_prohib log all from not me to any out $via_all

# Filter packets inbound on known interfaces
via_check=""

for (( index=0; index < intf_count; index++ )); do
    netw=${networks[$index]}
    intf=${interfaces[$index]}

    if [[ $netw == any ]]; then
	if [[ -z "$via_check" ]]; then
	    via_check="{"
	else
	    via_check="$via_check or"
	fi
	via_check="$via_check via $intf"
    fi
done

if [[ -n "$via_check" ]]; then
    via_check="$via_check }"
fi

for (( index=0; index < intf_count; index++ )); do
    netw=${networks[$index]}
    intf=${interfaces[$index]}

    if [[ $netw != any ]]; then
	$IPFW add $((7200 + index)) set 7 skipto 7500 \
	    all from $netw to me in via $intf
    fi
done

if [[ -n "$via_check" ]]; then
    # Deny all inbound traffic from RFC1918 address spaces (spoof!)
    $IPFW add $((7300 + index)) set 7 deny log \
	all from 192.168.0.0/16 to any in $via_check
    $IPFW add $((7320 + index)) set 7 deny log \
	all from 172.16.0.0/12 to any in $via_check
    $IPFW add $((7340 + index)) set 7 deny log \
	all from 10.0.0.0/8 to any in $via_check

    # Deny all inbound traffic from a loopback address (spoof!)
    $IPFW add $((7400 + index)) set 7 deny log \
	all from 127.0.0.0/8 to any in $via_check
fi

# Reject broadcasts not related to DHCP
$IPFW add 7500 set 7 $unreach_host_prohib $logall all from 0.0.0.0/8 to any not 67-68 in

# Reject DHCP auto-config, and public class D & E multicast
$IPFW add 7600 set 7 $unreach_host_prohib $logall all from 169.254.0.0/16 to any in
$IPFW add 7610 set 7 $unreach_host_prohib $logall all from 224.0.0.0/3 to any in

# Send TCP RST on attempted auth connections; IRC and SMTP might try
# to connect back to us legitimately
$IPFW add 7700 set 7 $tcp_reset $logall tcp from any to me 113 in setup


##############################################################################
#
# Set 10: Shape outbound traffic
#
# Outbound traffic is shaped for best response while concurrent
# transfers might be occurring in both directions.  The actual shaping
# is done at a much earlier step, even though we set it up at this
# point in the script.
#
##############################################################################

$IPFW set disable 10

for (( index=0; index < intf_count; index++ )); do
    limit_intf ${interfaces[$index]} ${inbw[$index]} ${outbw[$index]}
done

if [[ $intf_count > 0 ]]; then
    $IPFW set enable 10
fi


##############################################################################
#
# Set 11: Allow all outbound traffic
#
# If this ruleset is enabled, all other outbound traffic will be allowed
# here.  I use the application Little Snitch to allow/deny outbound
# packets on a per-Application basis.
#
# Note that all "known" outbound traffic is silently allowed, whereas
# unknown traffic is logged.  If the --stealth option is used, unknown
# traffic is logged and denied.
#
##############################################################################

$IPFW set disable 11

tcp_out_ports="80,443"		                    # Web
tcp_out_ports="$tcp_out_ports,21"		    # FTP
tcp_out_ports="$tcp_out_ports,22"		    # OpenSSH
tcp_out_ports="$tcp_out_ports,5900"		    # VNC
tcp_out_ports="$tcp_out_ports,5222,5190,5050,1863"  # IM
tcp_out_ports="$tcp_out_ports,6667"		    # IRC
tcp_out_ports="$tcp_out_ports,25,26"		    # SMTP
tcp_out_ports="$tcp_out_ports,110"		    # POP3
tcp_out_ports="$tcp_out_ports,995"		    # POP3S
tcp_out_ports="$tcp_out_ports,143"		    # IMAP4
tcp_out_ports="$tcp_out_ports,993"		    # IMAP4S

udp_out_ports="1194"		                    # OpenVPN
udp_out_ports="$udp_out_ports,53"		    # DNS
udp_out_ports="$udp_out_ports,123"		    # NTP

$IPFW add 11000 set 11 allow $logall \
    tcp from me to any $tcp_out_ports out $via_all setup keep-state

$IPFW add 11100 set 11 allow $logall udp \
    from me to any $udp_out_ports out $via_all keep-state

$IPFW add 11200 set 11 allow $logall tcp from me to any out $via_all setup keep-state
$IPFW add 11210 set 11 allow $logall ip from me to any out $via_all keep-state

if [[ $intf_count > 0 ]]; then
    $IPFW set enable 11
fi


##############################################################################
#
# Set 20: Allowing specified inbound traffic
#
# Ports can be opened for inbound traffic using the following options
# when invoking this script:
#
#   --trusted-tcp PORT[,PORT...]
#   --local-tcp PORT[,PORT...]
#   --tcp PORT[,PORT...]
#
#   --trusted-udp PORT[,PORT...]
#   --local-udp PORT[,PORT...]
#   --udp PORT[,PORT...]
#
# These options can specified a group of ports separated by commas, such
# as "--tcp 80,443", or you can give the same option multiple times,
# such as "--tcp 80 --tcp 443".
#
# The default, if no options are given, is to allow nothing.
#
##############################################################################

$IPFW set disable 20

for (( index=0; index < intf_count; index++ )); do
    netw=${networks[$index]}
    intf=${interfaces[$index]}

    if [[ ${trust[$index]} != false ]]; then
	if [[ -n "$trusted_tcp_ports" ]]; then
	    $IPFW add $((20000 + index)) set 20 allow tcp $logall \
		from $netw to me $trusted_tcp_ports \
		in via $intf setup keep-state
	fi
	if [[ -n "$trusted_udp_ports" ]]; then
	    $IPFW add $((20020 + index)) set 20 allow udp $logall \
		from $netw to me $trusted_udp_ports \
		in via $intf keep-state
	fi
    fi

    if [[ $netw != any || ${trust[$index]} != false ]]; then
	if [[ -n "$local_tcp_ports" ]]; then
	    $IPFW add $((20100 + index)) set 20 allow tcp $logall \
		from $netw to me $local_tcp_ports \
		in via $intf setup keep-state
	fi
	if [[ -n "$local_udp_ports" ]]; then
	    $IPFW add $((20120 + index)) set 20 allow udp $logall \
		from $netw to me $local_udp_ports \
		in via $intf keep-state
	fi
    fi

    if [[ -n "$public_tcp_ports" ]]; then
	$IPFW add $((20200 + index)) set 20 allow tcp $logall \
	    from $netw to me $public_tcp_ports \
	    in via $intf setup keep-state
    fi
    if [[ -n "$public_udp_ports" ]]; then
	$IPFW add $((20220 + index)) set 20 allow udp $logall \
	    from $netw to me $public_udp_ports \
	    in via $intf keep-state
    fi
done

if [[ $intf_count > 0 ]]; then
    $IPFW set enable 20
fi


##############################################################################
#
# Set 30: Reject ALL remaining packets, in or out
#
# Disabling this rule set will cause the default behavior to be to allow
# all packets not rejected by the above rules.
#
##############################################################################

# Reject certain packets that seem to fly around with no purpose
$IPFW add 30000 set 30 $unreach_host_prohib $logall udp from any 53 to any in $via_all
$IPFW add 30010 set 30 $unreach_host_prohib $logall udp from any to any 53 in $via_all

# Deny all traffic in or out, but divide the log between packets
# inbound on known interfaces and all other packets
$IPFW add 30100 set 30 $unreach_filter_prohib $logall udp from any to any in $via_all
$IPFW add 30110 set 30 $unreach_filter_prohib log tcp from any to any in $via_all
$IPFW add 30120 set 30 $unreach_filter_prohib $logall all from any to any in $via_all

# Deny all outbound traffic reaching this point, and log it so we know
# what the machine was trying to do
$IPFW add 30200 set 30 $unreach_filter_prohib log all from any to any out $via_all

# Lastly, we simply drop it all.
$IPFW add 30300 set 30 $unreach_filter_prohib $logall all from any to any


##############################################################################
#
# END: Inform the system that the firewall is now installed
#
##############################################################################

logger -i -p daemon.notice -t firewall "firewall installed: $args"

# ends here
