// Minimal rotating cube using modern OpenGL (Core 3.2)
#include <GLFW/glfw3.h>

#ifdef __APPLE__

#define GL_SILENCE_DEPRECATION
#include <OpenGL/gl3.h>
#else
#include <GL/gl.h>
#endif

#include <cmath>
#include <cstdio>
#include <vector>

static const char* kVertexSrc = R"( #version 150 core
in vec3 aPos;
in vec3 aColor;
out vec3 vColor;
uniform mat4 uMVP;
void main(){
  vColor = aColor;
  gl_Position = uMVP * vec4(aPos, 1.0);
}
)";

static const char* kFragmentSrc = R"( #version 150 core
in vec3 vColor;
out vec4 FragColor;
void main(){
  FragColor = vec4(vColor, 1.0);
}
)";

static GLuint compileShader(GLenum type, const char* src){
    GLuint sh = glCreateShader(type);
    glShaderSource(sh, 1, &src, nullptr);
    glCompileShader(sh);
    GLint ok = 0; glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
    if(!ok){
        GLint len=0; glGetShaderiv(sh, GL_INFO_LOG_LENGTH, &len);
        std::vector<char> log(len);
        glGetShaderInfoLog(sh, len, nullptr, log.data());
        std::fprintf(stderr, "Shader compile error: %s\n", log.data());
    }
    return sh;
}

static GLuint linkProgram(const char* vs, const char* fs){
    GLuint v = compileShader(GL_VERTEX_SHADER, vs);
    GLuint f = compileShader(GL_FRAGMENT_SHADER, fs);
    GLuint p = glCreateProgram();
    glAttachShader(p, v);
    glAttachShader(p, f);
    glBindAttribLocation(p, 0, "aPos");
    glBindAttribLocation(p, 1, "aColor");
    glLinkProgram(p);
    GLint ok=0; glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if(!ok){
        GLint len=0; glGetProgramiv(p, GL_INFO_LOG_LENGTH, &len);
        std::vector<char> log(len);
        glGetProgramInfoLog(p, len, nullptr, log.data());
        std::fprintf(stderr, "Program link error: %s\n", log.data());
    }
    glDeleteShader(v);
    glDeleteShader(f);
    return p;
}

struct Mat4 { float m[16]; };

static Mat4 matIdentity(){ Mat4 r{}; for(int i=0;i<16;++i) r.m[i]=0; r.m[0]=r.m[5]=r.m[10]=r.m[15]=1; return r; }
static Mat4 matMul(const Mat4& a, const Mat4& b){
    Mat4 r{}; for(int c=0;c<4;++c){ for(int rI=0;rI<4;++rI){ r.m[c*4+rI] =
        a.m[0*4+rI]*b.m[c*4+0] + a.m[1*4+rI]*b.m[c*4+1] + a.m[2*4+rI]*b.m[c*4+2] + a.m[3*4+rI]*b.m[c*4+3]; }} return r; }
static Mat4 matPerspective(float fovyRad, float aspect, float znear, float zfar){
    float f = 1.0f/std::tan(fovyRad/2.0f); Mat4 r{}; for(int i=0;i<16;++i) r.m[i]=0;
    r.m[0]=f/aspect; r.m[5]=f; r.m[10]=(zfar+znear)/(znear - zfar); r.m[11]=-1.0f; r.m[14]=(2*zfar*znear)/(znear - zfar);
    return r;
}
static Mat4 matTranslate(float x,float y,float z){ Mat4 r=matIdentity(); r.m[12]=x; r.m[13]=y; r.m[14]=z; return r; }
static Mat4 matRotateY(float a){ Mat4 r=matIdentity(); float c=std::cos(a), s=std::sin(a); r.m[0]=c; r.m[2]=s; r.m[8]=-s; r.m[10]=c; return r; }
static Mat4 matRotateX(float a){ Mat4 r=matIdentity(); float c=std::cos(a), s=std::sin(a); r.m[5]=c; r.m[6]=s; r.m[9]=-s; r.m[10]=c; return r; }

int main(){
    if(!glfwInit()) return -1;

    glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 2);
    glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);
    glfwWindowHint(GLFW_OPENGL_FORWARD_COMPAT, GL_TRUE);

    GLFWwindow* win = glfwCreateWindow(800, 600, "Hello OpenGL", nullptr, nullptr);
    if(!win){ glfwTerminate(); return -1; }

    glfwMakeContextCurrent(win);
    glfwSwapInterval(1);

    // Create shader program
    GLuint program = linkProgram(kVertexSrc, kFragmentSrc);
    GLint locMVP = glGetUniformLocation(program, "uMVP");

    // Cube geometry: positions + colors (interleaved)
    // 36 vertices (6 faces * 2 tris * 3 verts), each 6 floats
    const float v[] = {
        // +X (red)
        0.5f,-0.5f,-0.5f, 1,0,0,  0.5f, 0.5f,-0.5f, 1,0,0,  0.5f, 0.5f, 0.5f, 1,0,0,
        0.5f,-0.5f,-0.5f, 1,0,0,  0.5f, 0.5f, 0.5f, 1,0,0,  0.5f,-0.5f, 0.5f, 1,0,0,
        // -X (green)
       -0.5f,-0.5f, 0.5f, 0,1,0, -0.5f, 0.5f, 0.5f, 0,1,0, -0.5f, 0.5f,-0.5f, 0,1,0,
       -0.5f,-0.5f, 0.5f, 0,1,0, -0.5f, 0.5f,-0.5f, 0,1,0, -0.5f,-0.5f,-0.5f, 0,1,0,
        // +Y (blue)
       -0.5f, 0.5f,-0.5f, 0,0,1,  0.5f, 0.5f,-0.5f, 0,0,1,  0.5f, 0.5f, 0.5f, 0,0,1,
       -0.5f, 0.5f,-0.5f, 0,0,1,  0.5f, 0.5f, 0.5f, 0,0,1, -0.5f, 0.5f, 0.5f, 0,0,1,
        // -Y (yellow)
       -0.5f,-0.5f, 0.5f, 1,1,0,  0.5f,-0.5f, 0.5f, 1,1,0,  0.5f,-0.5f,-0.5f, 1,1,0,
       -0.5f,-0.5f, 0.5f, 1,1,0,  0.5f,-0.5f,-0.5f, 1,1,0, -0.5f,-0.5f,-0.5f, 1,1,0,
        // +Z (magenta)
       -0.5f,-0.5f, 0.5f, 1,0,1,  0.5f,-0.5f, 0.5f, 1,0,1,  0.5f, 0.5f, 0.5f, 1,0,1,
       -0.5f,-0.5f, 0.5f, 1,0,1,  0.5f, 0.5f, 0.5f, 1,0,1, -0.5f, 0.5f, 0.5f, 1,0,1,
        // -Z (cyan)
        0.5f, 0.5f,-0.5f, 0,1,1, -0.5f, 0.5f,-0.5f, 0,1,1, -0.5f,-0.5f,-0.5f, 0,1,1,
        0.5f, 0.5f,-0.5f, 0,1,1, -0.5f,-0.5f,-0.5f, 0,1,1,  0.5f,-0.5f,-0.5f, 0,1,1,
    };

    GLuint vao=0, vbo=0;
    glGenVertexArrays(1, &vao);
    glBindVertexArray(vao);
    glGenBuffers(1, &vbo);
    glBindBuffer(GL_ARRAY_BUFFER, vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(v), v, GL_STATIC_DRAW);

    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, sizeof(float)*6, (void*)0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, sizeof(float)*6, (void*)(sizeof(float)*3));

    glEnable(GL_DEPTH_TEST);

    while(!glfwWindowShouldClose(win)){
        int w=800, h=600;
        glfwGetFramebufferSize(win, &w, &h);
        glViewport(0, 0, w, h);
        glClearColor(0.1f, 0.2f, 0.2f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

        float t = static_cast<float>(glfwGetTime());
        float aspect = (h!=0) ? (float)w/(float)h : 1.3333f;

        Mat4 P = matPerspective(45.0f * 3.1415926f/180.0f, aspect, 0.1f, 100.0f);
        Mat4 V = matTranslate(0, 0, -3.0f);
        Mat4 R = matMul(matRotateY(t), matRotateX(t*0.7f));
        Mat4 M = R; // origin
        Mat4 MVP = matMul(P, matMul(V, M));

        glUseProgram(program);
        glUniformMatrix4fv(locMVP, 1, GL_FALSE, MVP.m);
        glBindVertexArray(vao);
        glDrawArrays(GL_TRIANGLES, 0, 36);

        glfwSwapBuffers(win);
        glfwPollEvents();
    }

    glDeleteBuffers(1, &vbo);
    glDeleteVertexArrays(1, &vao);
    glDeleteProgram(program);
    glfwDestroyWindow(win);
    glfwTerminate();
    return 0;
}
