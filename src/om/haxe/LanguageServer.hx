package om.haxe;

import js.Browser.console;
import js.node.Buffer;
import js.node.ChildProcess;
import js.node.child_process.ChildProcess as Process;
import js.node.child_process.ChildProcess.ChildProcessEvent;
import js.node.stream.Readable;

using StringTools;

class LanguageServer {

//	public var onDebug(default,null) = new Emitter();

	public var haxePath(default,null) : String;
	public var verbose : Bool;

	var proc : Process;
	var buffer : MessageBuffer;
	var nextMessageLength : Int;
	var currentRequest : Request;
	var requestsHead : Request;
    var requestsTail : Request;

	public function new( haxePath = 'haxe', verbose = false ) {
		this.haxePath = haxePath;
		this.verbose = verbose;
	}

	public inline function isActive() : Bool
		return proc != null;

	public function start( callback : String->Void, ?onDebug : String->Void ) {

		stop();

		buffer = new MessageBuffer();
		nextMessageLength = -1;

		var args = ['-v','--wait','stdio'];

		// TODO
		// HACK
		//var cwd = Atom.project.getPaths()[0];
		//if( sys.FileSystem.exists( '$cwd/src' ) ) cwd += '/src';

		//proc = ChildProcess.spawn( haxePath, args, { cwd: cwd } );
		proc = ChildProcess.spawn( haxePath, args );
		proc.on( ChildProcessEvent.Exit, handleExit );
		proc.stderr.on( ReadableEvent.Data, handleData );

		if( onDebug != null ) {
			proc.stdout.on( ReadableEvent.Data, function(buf:Buffer) {
				//#if debug
				var str = buf.toString();
				onDebug( str );
			//	if( verbose ) {
					//console.log( str );
					//console.debug( '%c'+str, 'color:#EA8220;' );
			//	}
				//onDebug.emit( 'message', str );
				//#end
			});
		}

		/*
		getVersion( function(v){
			var version : om.Version = v;
			callback( (version < '3.4.0') ? 'haxe >= 3.4.0 required' : null );
		});
		*/

		callback( null );
	}

	public function stop() {
		if( proc != null ) {
            proc.removeAllListeners();
			try proc.kill() catch(e:Dynamic) { trace(e); }
            proc = null;
        }
		var req = requestsHead;
        while( req != null ) {
            req.processResult( null );
            req = req.next;
        }
        requestsHead = requestsTail = currentRequest = null;
	}

	public function getVersion( callback : String->Void ) {
		query( ['-version'], null, callback, function(e) trace(e) );
	}

	public function query( args : Array<String>, ?stdin : String, onResult : String->Void, onError : String->Void, ?onMessage : String->Void ) {
		var req = new Request( args, stdin, onResult, onError, onMessage );
		if( requestsHead == null ) {
            requestsHead = requestsTail = req;
		} else {
			requestsTail.next = req;
            req.prev = requestsTail;
            requestsTail = req;
		}
		checkQueue();
	}

	function checkQueue() {
        if( currentRequest != null )
            return;
        if( requestsHead != null ) {
            currentRequest = requestsHead;
            requestsHead = currentRequest.next;
            proc.stdin.write( currentRequest.prepareBody() );
        }
    }

	function handleData( buf : Buffer ) {
		buffer.append( buf );
		while( true ) {
			if( nextMessageLength == -1 ) {
				var length = buffer.tryReadLength();
				if( length == -1 )
					return;
				nextMessageLength = length;
			}
			var msg = buffer.tryReadContent( nextMessageLength );
			if( msg == null )
				return;
			nextMessageLength = -1;
			if( currentRequest != null ) {
				var request = currentRequest;
                currentRequest = null;
				request.processResult( msg );
                checkQueue();
			}
		}
	}

	function handleExit(a,b) {
		//TODO
	   trace("Haxe process was killed");
	   trace(a);
	   trace(b);
	}
}

private class MessageBuffer {

	var size : Int;
	var buffer : Buffer;
	var index : Int;

	public function new( size = 8192 ) {
		this.size = size;
		this.buffer = new Buffer( size );
		this.index = 0;
	}

	public function append( chunk : Buffer ) {
		if( buffer.length - index >= chunk.length ) {
            chunk.copy( buffer, index, 0, chunk.length );
        } else {
            var nsize = Std.int( (Math.ceil((index + chunk.length) / size) + 1) * size );
            if( index == 0 ) {
                buffer = new Buffer( nsize );
                chunk.copy( buffer, 0, 0, chunk.length );
            } else {
                buffer = Buffer.concat( [buffer.slice( 0, index ), chunk], nsize );
            }
        }
        index += chunk.length;
	}

	public function tryReadLength() : Int {
		if( index < 4 )
            return -1;
        var len = buffer.readInt32LE( 0 );
        buffer = buffer.slice( 4 );
        index -= 4;
        return len;
	}

	public function tryReadContent( length : Int ) : String {
        if( index < length )
            return null;
        var res = buffer.toString( "utf-8", 0, length );
        var nstart = length;
        buffer.copy( buffer, 0, nstart );
        index -= nstart;
        return res;
    }
}

private class Request {

	@:allow(om.haxe.LanguageServer) var prev : Request;
    @:allow(om.haxe.LanguageServer) var next : Request;

    var args : Array<String>;
    var stdin : String;
	var onMessage : String->Void;
    var onResult : String->Void;
    var onError : String->Void;

	public function new( args : Array<String>, stdin : String, onResult : String->Void, onError : String->Void, ?onMessage : String->Void ) {
        this.args = args;
        this.stdin = stdin;
        this.onResult = onResult;
        this.onError = onError;
		this.onMessage = onMessage;
    }

	public function prepareBody() : Buffer {

        if( stdin != null ) args = args.concat( ['-D','display-stdin'] );

        var lbuf = new Buffer(4);
        var chunks = [lbuf];
        var length = 0;

        for( arg in args ) {
            var buf = new Buffer( '$arg\n' );
            chunks.push( buf );
            length += buf.length;
        }

        if( stdin != null ) {
			var sbuf = new Buffer( [1] );
            chunks.push( sbuf );
            var buf = new Buffer( stdin );
            chunks.push( buf );
            length += buf.length + sbuf.length;
        }

        lbuf.writeInt32LE( length, 0 );

        return Buffer.concat( chunks, length + 4 );
    }

    public function processResult( data : String ) {

        if( data == null ) {
			onResult( null );
			return;
		}

        var buf = new StringBuf();
        var hasError = false;
        for( line in data.split( "\n" ) ) {
			var code = line.fastCodeAt( 0 );
            switch code {
                case 0x01: // print
                    var line = line.substring( 1 ).replace( "\x01", "\n" );
                    //trace("Haxe print:\n" + line);
					//onResult( line );
					if( onMessage != null ) onMessage( line );
                case 0x02: // error
                    hasError = true;
				case 0x41: // warning ("<")
					if( onMessage != null ) onMessage( line );
                default:
                    buf.add( line );
                    buf.addChar( "\n".code );
            }
        }

        var data = buf.toString().trim();
		/*
        if( hasError )
            return onError( "Error from Haxe server: " + data );
        try {
            onResult( data );
        } catch (e:Any) {
			trace(e);
			onError(e);
            //errback(jsonrpc.ErrorUtils.errorToString(e, "Exception while handling Haxe completion response: "));
        }
		*/
		if( hasError ) {
			onError( data );
		} else {
			onResult( data );
		}

    }

}
