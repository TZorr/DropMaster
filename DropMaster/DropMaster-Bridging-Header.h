//
//  DropMaster-Bridging-Header.h
//  DropMaster
//
//  The one C dependency: libmp3lame, for MP3 export. Core Audio writes every
//  other export format itself, but it has never shipped an MP3 encoder. The
//  library's sources sit in DropMaster/LAME and compile straight into the
//  target (see config.h there); this header makes lame.h visible to Swift.
//

#import "lame.h"
