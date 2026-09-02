#ifndef GUEST_CTYPE_H
#define GUEST_CTYPE_H
#ifdef __cplusplus
extern "C" {
#endif
int isspace(int c);
int isdigit(int c);
int isxdigit(int c);
int isalpha(int c);
int isalnum(int c);
int isprint(int c);
int isupper(int c);
int islower(int c);
int toupper(int c);
int tolower(int c);
#ifdef __cplusplus
}
#endif
#endif
