/*
 * The dylib's public surface: three accessors, nothing else.
 *
 * The unix half is compiled with -fvisibility=hidden, so its own entry points cannot be
 * exported from a shared image even when named in an export list. Rather than relax that
 * flag for the whole half (which would export every internal symbol and let the dylib
 * interpose on the app), this file is the one default-visible object in the image. It
 * forwards to the hidden symbols, which it can reach because it is linked into the same
 * dylib.
 *
 * `madeira_` prefix on purpose: the archive copy of the half is still linked into the app
 * as the fallback, and these must never collide with anything the app or Wine defines.
 *
 *   madeira_unix_half_main                 -> __wine_main( argc, argv )
 *   madeira_unix_half_log_set_file(path)   -> wine_log_set_file( path )
 *   madeira_unix_half_main_i386_addr()     -> &ios_main_image_i386
 *
 * The third is a write target: the app sets the main image's machine before starting Wine
 * so the unix side reserves the WoW64 guest window before its first TEB. Because the flag
 * lives in the half, a caller that wrote the app's linked copy would be writing to a
 * variable this image never reads.
 */

void __wine_main( int argc, char *argv[] );
void wine_log_set_file( const char *path );
extern int ios_main_image_i386;

__attribute__((visibility("default")))
void madeira_unix_half_main( int argc, char *argv[] )
{
    __wine_main( argc, argv );
}

__attribute__((visibility("default")))
void madeira_unix_half_log_set_file( const char *path )
{
    wine_log_set_file( path );
}

__attribute__((visibility("default")))
int *madeira_unix_half_main_i386_addr( void )
{
    return &ios_main_image_i386;
}
