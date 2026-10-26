import axios from 'axios'

const api = axios.create({
  baseURL: '/api',
  withCredentials: true,
})

api.interceptors.response.use(
  (res) => res,
  (err) => {
    if (err.response && err.response.status === 401) {
      const publicPages = ['/login', '/register', '/pqc-login']
      
      // Only redirect if we are NOT already on a public login page
      if (!publicPages.includes(location.pathname)) {
        localStorage.removeItem('token')
        localStorage.removeItem('username')
        localStorage.removeItem('role')
        location.href = '/login'
      }
    }
    return Promise.reject(err)
  }
)

export default api
