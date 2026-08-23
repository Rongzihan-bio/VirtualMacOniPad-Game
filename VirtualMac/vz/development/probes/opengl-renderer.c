#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <stdio.h>
#include <string.h>

static const char *gl_string(GLenum name) {
    const GLubyte *value = glGetString(name);
    return value != NULL ? (const char *)value : "(null)";
}

static int has_argument(int argc, char **argv, const char *argument) {
    for (int index = 1; index < argc; ++index) {
        if (strcmp(argv[index], argument) == 0)
            return 1;
    }
    return 0;
}

static GLuint compile_shader(GLenum type, const char *source) {
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);
    GLint compiled = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (!compiled) {
        char log[2048] = {0};
        glGetShaderInfoLog(shader, sizeof(log), NULL, log);
        fprintf(stderr, "shader compile failed: %s\n", log);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

static GLuint make_triangle_program(int useUniform) {
    static const char *vertexSource =
        "#version 150\n"
        "in vec2 position;\n"
        "void main() { gl_Position = vec4(position, 0.0, 1.0); }\n";
    static const char *fragmentSource =
        "#version 150\n"
        "out vec4 color;\n"
        "void main() { color = vec4(1.0, 0.0, 1.0, 1.0); }\n";
    static const char *uniformFragmentSource =
        "#version 150\n"
        "uniform vec4 chosenColor;\n"
        "out vec4 color;\n"
        "void main() { color = chosenColor; }\n";
    GLuint vertex = compile_shader(GL_VERTEX_SHADER, vertexSource);
    GLuint fragment = compile_shader(GL_FRAGMENT_SHADER,
        useUniform ? uniformFragmentSource : fragmentSource);
    if (!vertex || !fragment)
        return 0;
    GLuint program = glCreateProgram();
    glAttachShader(program, vertex);
    glAttachShader(program, fragment);
    glBindAttribLocation(program, 0, "position");
    glLinkProgram(program);
    glDeleteShader(vertex);
    glDeleteShader(fragment);
    GLint linked = 0;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (!linked) {
        char log[2048] = {0};
        glGetProgramInfoLog(program, sizeof(log), NULL, log);
        fprintf(stderr, "program link failed: %s\n", log);
        glDeleteProgram(program);
        return 0;
    }
    return program;
}

int main(int argc, char **argv) {
    CGLPixelFormatAttribute acceleratedAttributes[] = {
        kCGLPFAOpenGLProfile,
        (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
        kCGLPFAAccelerated,
        (CGLPixelFormatAttribute)0,
    };
    CGLPixelFormatAttribute softwareAttributes[] = {
        kCGLPFAOpenGLProfile,
        (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
        (CGLPixelFormatAttribute)0,
    };
    CGLPixelFormatObj pixelFormat = NULL;
    GLint pixelFormatCount = 0;
    CGLError error = CGLChoosePixelFormat(
        acceleratedAttributes, &pixelFormat, &pixelFormatCount);
    printf("choose-accelerated error=%d (%s) count=%d\n", error,
           CGLErrorString(error), pixelFormatCount);
    if (error != kCGLNoError || pixelFormat == NULL) {
        pixelFormatCount = 0;
        error = CGLChoosePixelFormat(
            softwareAttributes, &pixelFormat, &pixelFormatCount);
        printf("choose-fallback error=%d (%s) count=%d\n", error,
               CGLErrorString(error), pixelFormatCount);
        if (error != kCGLNoError || pixelFormat == NULL)
            return 1;
    }

    GLint accelerated = 0;
    GLint rendererID = 0;
    CGLDescribePixelFormat(pixelFormat, 0, kCGLPFAAccelerated,
                           &accelerated);
    CGLDescribePixelFormat(pixelFormat, 0, kCGLPFARendererID,
                           &rendererID);
    printf("pixel-format accelerated=%d renderer-id=0x%x\n",
           accelerated, rendererID);

    CGLContextObj context = NULL;
    error = CGLCreateContext(pixelFormat, NULL, &context);
    printf("create error=%d (%s) context=%p\n", error,
           CGLErrorString(error), context);
    if (error != kCGLNoError || context == NULL) {
        CGLDestroyPixelFormat(pixelFormat);
        return 2;
    }
    CGLSetCurrentContext(context);
    printf("vendor=%s\nrenderer=%s\nversion=%s\n",
           gl_string(GL_VENDOR), gl_string(GL_RENDERER),
           gl_string(GL_VERSION));

    GLuint texture = 0;
    GLuint framebuffer = 0;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 64, 64, 0,
                 GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                           GL_TEXTURE_2D, texture, 0);
    GLenum framebufferStatus = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    glViewport(0, 0, 64, 64);
    glClearColor(0.25f, 0.5f, 0.75f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    GLuint vertexArray = 0;
    GLuint vertexBuffer = 0;
    GLuint indexBuffer = 0;
    GLuint program = 0;
    if (has_argument(argc, argv, "--triangle")) {
        const GLfloat vertices[] = {-1.0f, -1.0f, 3.0f, -1.0f,
                                    -1.0f, 3.0f};
        int useUniform = has_argument(argc, argv, "--uniform");
        program = make_triangle_program(useUniform);
        glGenVertexArrays(1, &vertexArray);
        glBindVertexArray(vertexArray);
        glGenBuffers(1, &vertexBuffer);
        glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer);
        glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices,
                     GL_STATIC_DRAW);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, NULL);
        glUseProgram(program);
        if (useUniform) {
            GLint location = glGetUniformLocation(program, "chosenColor");
            glUniform4f(location, 1.0f, 0.0f, 1.0f, 1.0f);
        }
        if (has_argument(argc, argv, "--indexed")) {
            const GLushort indices[] = {0, 1, 2};
            glGenBuffers(1, &indexBuffer);
            glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, indexBuffer);
            glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(indices), indices,
                         GL_STATIC_DRAW);
            glDrawElements(GL_TRIANGLES, 3, GL_UNSIGNED_SHORT, NULL);
        } else {
            glDrawArrays(GL_TRIANGLES, 0, 3);
        }
    }
    glFinish();
    printf("clear-finished gl-error=0x%x\n", glGetError());
    fflush(stdout);
    if (has_argument(argc, argv, "--no-readback"))
        goto cleanup;
    unsigned char pixel[4] = {0};
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    GLenum glError = glGetError();
    printf("fbo-status=0x%x pixel=%u,%u,%u,%u gl-error=0x%x\n",
           framebufferStatus, pixel[0], pixel[1], pixel[2], pixel[3],
           glError);
cleanup:
    if (vertexBuffer)
        glDeleteBuffers(1, &vertexBuffer);
    if (indexBuffer)
        glDeleteBuffers(1, &indexBuffer);
    if (vertexArray)
        glDeleteVertexArrays(1, &vertexArray);
    if (program)
        glDeleteProgram(program);
    glDeleteFramebuffers(1, &framebuffer);
    glDeleteTextures(1, &texture);
    CGLSetCurrentContext(NULL);
    CGLDestroyContext(context);
    CGLDestroyPixelFormat(pixelFormat);
    return 0;
}
